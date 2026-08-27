defmodule IexCode.Tools.TerminalSupervisor do
  @moduledoc """
  DynamicSupervisor managing active `IexCode.Tools.TerminalSession` processes.
  Guarantees failure isolation between workspace terminals and provides lifecycle management.
  """
  use DynamicSupervisor
  require Logger

  alias IexCode.Tools.TerminalSession

  @history_cache :iex_code_terminal_command_history
  @history_cache_max_sessions 128

  @doc """
  Starts the DynamicSupervisor.
  """
  def start_link(init_arg \\ []) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    ensure_history_cache()
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc false
  def cached_history(session_id) when is_binary(session_id) do
    case :ets.whereis(@history_cache) do
      :undefined ->
        []

      _table ->
        case :ets.lookup(@history_cache, session_id) do
          [{^session_id, history, _updated_at}] when is_list(history) -> history
          _other -> []
        end
    end
  end

  @doc false
  def cache_history(session_id, history) when is_binary(session_id) and is_list(history) do
    case :ets.whereis(@history_cache) do
      :undefined ->
        :ok

      _table ->
        true =
          :ets.insert(
            @history_cache,
            {session_id, history, System.monotonic_time(:millisecond)}
          )

        prune_history_cache()
        :ok
    end
  end

  @doc false
  def clear_cached_history(session_id) when is_binary(session_id) do
    case :ets.whereis(@history_cache) do
      :undefined ->
        :ok

      _table ->
        true = :ets.delete(@history_cache, session_id)
        :ok
    end
  end

  @doc """
  Starts or retrieves an active TerminalSession under dynamic supervision.
  Returns `{:ok, pid}` or `{:error, reason}`.
  """
  @spec start_session(session_id :: String.t(), opts :: keyword()) ::
          {:ok, pid()} | {:error, term()}
  def start_session(session_id, opts \\ []) when is_binary(session_id) do
    child_spec = {TerminalSession, Keyword.put(opts, :session_id, session_id)}

    case DynamicSupervisor.start_child(__MODULE__, child_spec) do
      {:ok, pid} ->
        allow_sandbox(pid)
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        if is_pid(pid) and Process.alive?(pid) do
          allow_sandbox(pid)
          {:ok, pid}
        else
          Logger.warning(
            "TerminalSupervisor: stale already_started pid #{inspect(pid)} for session #{inspect(session_id)}; retrying"
          )

          DynamicSupervisor.start_child(__MODULE__, child_spec)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Terminates a running TerminalSession child process.
  """
  @spec stop_session(session_id :: String.t()) :: :ok | {:error, :not_found}
  def stop_session(session_id) when is_binary(session_id) do
    case TerminalSession.whereis(session_id) do
      nil ->
        {:error, :not_found}

      pid ->
        ref = Process.monitor(pid)
        res = DynamicSupervisor.terminate_child(__MODULE__, pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, _} -> :ok
        after
          2_000 -> :ok
        end

        case res do
          :ok -> :ok
          {:error, _} = err -> err
        end
    end
  end

  @doc """
  Returns a list of all active `{session_id, pid}` terminal sessions.
  """
  @spec list_sessions() :: [{String.t(), pid()}]
  def list_sessions do
    IexCode.SessionRegistry
    |> Registry.select([{{{:terminal, :"$1"}, :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.filter(fn {_id, pid} -> Process.alive?(pid) end)
  end

  @doc """
  Returns child count summary from DynamicSupervisor.
  """
  def count_children do
    DynamicSupervisor.count_children(__MODULE__)
  end

  @doc "Applies a new idle timeout to running terminals; future terminals read application config."
  def update_idle_timeout(timeout_ms) when is_integer(timeout_ms) and timeout_ms > 0 do
    Enum.each(list_sessions(), fn {session_id, _pid} ->
      TerminalSession.update_idle_timeout(session_id, timeout_ms)
    end)

    :ok
  end

  @doc """
  Returns active child tuples from DynamicSupervisor.
  """
  def which_children do
    DynamicSupervisor.which_children(__MODULE__)
  end

  defp allow_sandbox(pid) do
    if Code.ensure_loaded?(Ecto.Adapters.SQL.Sandbox) do
      try do
        Ecto.Adapters.SQL.Sandbox.allow(IexCode.Repo, self(), pid)
      rescue
        _ -> :ok
      catch
        _, _ -> :ok
      end
    end
  end

  defp ensure_history_cache do
    case :ets.whereis(@history_cache) do
      :undefined ->
        :ets.new(@history_cache, [
          :named_table,
          :public,
          :set,
          read_concurrency: true,
          write_concurrency: true
        ])

      _table ->
        @history_cache
    end
  end

  defp prune_history_cache do
    if :ets.info(@history_cache, :size) > @history_cache_max_sessions do
      case :ets.tab2list(@history_cache) do
        [] ->
          :ok

        rows ->
          {oldest_id, _history, _updated_at} = Enum.min_by(rows, &elem(&1, 2))
          :ets.delete(@history_cache, oldest_id)
      end
    end
  end
end
