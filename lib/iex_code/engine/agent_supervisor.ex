defmodule IexCode.Engine.AgentSupervisor do
  @moduledoc """
  DynamicSupervisor managing the lifecycles of dedicated subagent GenServers
  (PlannerAgent, ExplorerAgent, CoderAgent, VerifierAgent).
  """
  use DynamicSupervisor
  require Logger
  alias IexCode.Engine.AgentRegistry

  def start_link(init_arg \\ []) do
    name = Keyword.get(init_arg, :name, __MODULE__)
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: name)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Starts or retrieves a dedicated subagent GenServer process under supervision.
  Returns `{:ok, pid}` or `{:error, reason}`.
  """
  def start_agent(session_id, agent_type, opts \\ []) do
    do_start_agent(session_id, agent_type, opts, 3)
  end

  @doc "Starts one strictly allowlisted agent inside a durable run fleet."
  def start_run_agent(supervisor, run_id, agent_id, agent_type, opts \\ [])
      when is_binary(run_id) and is_binary(agent_id) do
    module = resolve_agent_module(agent_type)

    child_opts =
      opts
      |> Keyword.put(:run_id, run_id)
      |> Keyword.put(:agent_id, agent_id)
      |> Keyword.put(:agent_type, AgentRegistry.normalize_type(agent_type))

    child_spec = Supervisor.child_spec({module, child_opts}, restart: :temporary)

    case DynamicSupervisor.start_child(supervisor, child_spec) do
      {:ok, pid} ->
        allow_sandbox(pid)
        {:ok, pid}

      {:error, {:already_started, _pid}} ->
        {:error, :registration_conflict}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Stops exactly one durable run agent and never enumerates by session."
  def stop_run_agent(supervisor, run_id, agent_id) do
    case AgentRegistry.whereis_agent(run_id, agent_id) do
      nil -> {:error, :not_found}
      pid -> DynamicSupervisor.terminate_child(supervisor, pid)
    end
  end

  @doc "Stops all and only the agents registered to one durable run."
  def stop_run_agents(_supervisor, run_id) do
    pids =
      run_id
      |> AgentRegistry.list_run_agents()
      |> Enum.map(fn {_agent_id, pid, _metadata} -> pid end)

    stop_run_pids(pids)
  end

  @run_stop_deadline_ms 5_000

  @doc false
  def stop_run_pids(pids, grace_ms \\ @run_stop_deadline_ms)
      when is_list(pids) and is_integer(grace_ms) and grace_ms >= 0 do
    refs =
      pids
      |> Enum.filter(&(is_pid(&1) and Process.alive?(&1)))
      |> Enum.uniq()
      |> Map.new(fn pid ->
        ref = Process.monitor(pid)
        Process.exit(pid, :shutdown)
        {ref, pid}
      end)

    deadline = System.monotonic_time(:millisecond) + grace_ms
    remaining = await_run_agent_shutdowns(refs, deadline)

    Enum.each(remaining, fn {_ref, pid} ->
      if Process.alive?(pid), do: Process.exit(pid, :kill)
    end)

    kill_deadline = System.monotonic_time(:millisecond) + 1_000

    remaining
    |> await_run_agent_shutdowns(kill_deadline)
    |> Enum.each(fn {ref, _pid} -> Process.demonitor(ref, [:flush]) end)

    :ok
  end

  defp await_run_agent_shutdowns(refs, _deadline) when map_size(refs) == 0, do: refs

  defp await_run_agent_shutdowns(refs, deadline) do
    remaining_ms = max(deadline - System.monotonic_time(:millisecond), 0)

    if remaining_ms == 0 do
      refs
    else
      receive do
        {:DOWN, ref, :process, _pid, _reason} when is_map_key(refs, ref) ->
          await_run_agent_shutdowns(Map.delete(refs, ref), deadline)
      after
        remaining_ms -> refs
      end
    end
  end

  defp do_start_agent(_session_id, _agent_type, _opts, 0),
    do: {:error, :agent_start_retries_exhausted}

  defp do_start_agent(session_id, agent_type, opts, attempts) do
    module = resolve_agent_module(agent_type)
    child_spec = {module, Keyword.merge(opts, session_id: session_id)}

    case DynamicSupervisor.start_child(__MODULE__, child_spec) do
      {:ok, pid} ->
        allow_sandbox(pid)
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        # Race: the registered process may have already died; verify before reusing it.
        if is_pid(pid) and Process.alive?(pid) do
          allow_sandbox(pid)
          {:ok, pid}
        else
          Logger.warning(
            "AgentSupervisor: stale already_started pid #{inspect(pid)} for " <>
              "#{inspect(agent_type)} in session #{inspect(session_id)}; retrying start"
          )

          do_start_agent(session_id, agent_type, opts, attempts - 1)
        end

      {:error, reason} ->
        {:error, reason}
    end
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

  @doc """
  Terminates a subagent process if running.
  """
  def stop_agent(session_id, agent_type) do
    _ = :sys.get_state(AgentRegistry)

    case AgentRegistry.whereis(session_id, agent_type) do
      nil ->
        {:error, :not_found}

      pid ->
        ref = Process.monitor(pid)
        res = DynamicSupervisor.terminate_child(__MODULE__, pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, _} -> :ok
        after
          1_000 -> :ok
        end

        _ = :sys.get_state(AgentRegistry)
        res
    end
  end

  @doc """
  Terminates all running subagents for a session.

  Agents receive shutdown in parallel with a #{@run_stop_deadline_ms}ms grace period;
  any stragglers still alive past that deadline are killed and awaited.
  """
  def stop_all_agents(session_id) do
    _ = :sys.get_state(AgentRegistry)

    # Legacy agents use transient restart policies, so they must be removed
    # through DynamicSupervisor rather than raw Process.exit/2. A brutal kill
    # would otherwise be interpreted as a crash and spawn replacement agents.
    session_id
    |> AgentRegistry.list_agents()
    |> Task.async_stream(
      fn {_type, pid} -> DynamicSupervisor.terminate_child(__MODULE__, pid) end,
      max_concurrency: 4,
      ordered: false,
      timeout: @run_stop_deadline_ms,
      on_timeout: :kill_task
    )
    |> Stream.run()

    _ = :sys.get_state(AgentRegistry)
    :ok
  end

  @doc """
  Stops all in-flight autonomous work associated with a session.

  The terminal is restarted only when an agent currently owns the PTY, so an
  agent command and its process tree are killed without interrupting an idle
  user shell. Agent processes are then terminated, which also closes in-flight
  HTTP connections and ports owned by those GenServers.
  """
  def cancel_session_activity(session_id) when is_binary(session_id) do
    restart_agent_terminal(session_id)
    :ok = stop_all_agents(session_id)
    :ok
  end

  defp restart_agent_terminal(session_id) do
    case IexCode.Tools.TerminalServer.get_state(session_id) do
      {:ok, %{occupant: occupant}} when is_tuple(occupant) and elem(occupant, 0) == :agent ->
        case IexCode.Tools.TerminalServer.restart(session_id) do
          {:ok, _pid} -> :ok
          {:error, _reason} -> IexCode.Tools.TerminalServer.kill(session_id)
        end

      _other ->
        :ok
    end
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  @doc """
  Finds the PID of a subagent process for a given session and agent type.
  """
  def find_agent(session_id, agent_type) do
    AgentRegistry.whereis(session_id, agent_type)
  end

  @doc """
  Resolves the GenServer module corresponding to an agent type.

  Raises `ArgumentError` for unknown/junk types instead of returning a module
  that would crash later during `start_child`.
  """
  def resolve_agent_module(type) do
    case AgentRegistry.normalize_type(type) do
      :planner ->
        IexCode.Engine.Agents.PlannerAgent

      :explorer ->
        IexCode.Engine.Agents.ExplorerAgent

      :coder ->
        IexCode.Engine.Agents.CoderAgent

      :verifier ->
        IexCode.Engine.Agents.VerifierAgent

      other ->
        raise ArgumentError, "unknown agent type: #{inspect(other)}"
    end
  end
end
