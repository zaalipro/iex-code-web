defmodule IexCode.Observability.ETSPruner do
  @moduledoc """
  Supervised background GenServer that guarantees ETS tables cannot grow
  monotonically or exhaust memory over continuous, multi-hour runtime (>10h).

  Periodically sweeps ephemeral ETS tables:
  1. `:iex_code_swarm_peer_stream_history` (PeerStream): prunes messages older than TTL
     (default 30 mins) and enforces hard table size limits (default max 5,000 entries).
  2. `:iex_code_multipatch_snapshots` (MultiPatch): prunes in-memory cached snapshots older
     than TTL (default 2 hours) or when table size > 1,000 entries (authoritative state lives in SQLite).
  3. `IexCode.LLM.Resilience` (CircuitBreaker): removes expired circuit breaker cooldown entries.
  4. `:iex_code_terminal_command_history` (TerminalSupervisor): prunes entries for terminated sessions
     or older than 2 hours.
  5. `:iex_code_web_admin_auth_throttle` (AdminAuth): prunes expired rate-limit windows.

  Provides `prune_all/0` and `table_stats/0` for programmatic and testing usage.
  """

  use GenServer
  require Logger

  @default_sweep_interval_ms 60_000
  @default_peer_stream_ttl_seconds 1_800
  @default_peer_stream_max_entries 5_000
  @default_snapshot_ttl_seconds 7_200
  @default_snapshot_max_entries 1_000
  @default_terminal_history_ttl_ms 7_200_000
  @default_semantic_cache_max_entries 5_000

  # ============================================================================
  # Client API
  # ============================================================================

  @doc """
  Starts the ETSPruner GenServer.
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Performs an immediate synchronous sweep of all managed ETS tables and returns
  a map with counts of deleted entries.
  """
  @spec prune_all(GenServer.server()) :: map()
  def prune_all(server \\ __MODULE__) do
    case resolve_pid(server) do
      pid when is_pid(pid) ->
        try do
          GenServer.call(pid, :prune_all, 10_000)
        catch
          :exit, _ -> do_prune_all(%{})
        end

      nil ->
        do_prune_all(%{})
    end
  end

  @doc """
  Returns a summary map of managed ETS tables with entry counts and memory usage in words/bytes.
  """
  @spec table_stats() :: map()
  def table_stats do
    tables = [
      :iex_code_swarm_peer_stream_history,
      :iex_code_multipatch_snapshots,
      IexCode.LLM.Resilience,
      :iex_code_terminal_command_history,
      :iex_code_web_admin_auth_throttle,
      :iex_code_semantic_cache
    ]

    wordsize = :erlang.system_info(:wordsize)

    Enum.into(tables, %{}, fn table ->
      case :ets.info(table) do
        :undefined ->
          {table, %{exists?: false, size: 0, memory_bytes: 0}}

        info when is_list(info) ->
          size = Keyword.get(info, :size, 0)
          words = Keyword.get(info, :memory, 0)
          {table, %{exists?: true, size: size, memory_bytes: words * wordsize}}
      end
    end)
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    app_opts = Application.get_env(:iex_code, :ets_pruner, [])
    merged_opts = Keyword.merge(app_opts, opts)

    interval_ms = Keyword.get(merged_opts, :sweep_interval_ms, @default_sweep_interval_ms)
    enabled? = Keyword.get(merged_opts, :enabled, true)

    timer_ref =
      if enabled? and is_integer(interval_ms) and interval_ms > 0 do
        schedule_sweep(interval_ms)
      else
        nil
      end

    state = %{
      enabled?: enabled?,
      interval_ms: interval_ms,
      timer_ref: timer_ref,
      peer_stream_ttl_seconds:
        Keyword.get(merged_opts, :peer_stream_ttl_seconds, @default_peer_stream_ttl_seconds),
      peer_stream_max_entries:
        Keyword.get(merged_opts, :peer_stream_max_entries, @default_peer_stream_max_entries),
      snapshot_ttl_seconds:
        Keyword.get(merged_opts, :snapshot_ttl_seconds, @default_snapshot_ttl_seconds),
      snapshot_max_entries:
        Keyword.get(merged_opts, :snapshot_max_entries, @default_snapshot_max_entries),
      terminal_history_ttl_ms:
        Keyword.get(merged_opts, :terminal_history_ttl_ms, @default_terminal_history_ttl_ms),
      semantic_cache_max_entries:
        Keyword.get(merged_opts, :semantic_cache_max_entries, @default_semantic_cache_max_entries)
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:prune_all, _from, state) do
    result = do_prune_all(state)
    {:reply, result, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    _result = do_prune_all(state)
    timer_ref = if state.enabled?, do: schedule_sweep(state.interval_ms), else: nil
    {:noreply, %{state | timer_ref: timer_ref}}
  end

  # ============================================================================
  # Internal Pruning Logic
  # ============================================================================

  defp do_prune_all(config) do
    peer_stream_ttl = Map.get(config, :peer_stream_ttl_seconds, @default_peer_stream_ttl_seconds)
    peer_stream_max = Map.get(config, :peer_stream_max_entries, @default_peer_stream_max_entries)
    snapshot_ttl = Map.get(config, :snapshot_ttl_seconds, @default_snapshot_ttl_seconds)
    snapshot_max = Map.get(config, :snapshot_max_entries, @default_snapshot_max_entries)
    term_ttl = Map.get(config, :terminal_history_ttl_ms, @default_terminal_history_ttl_ms)

    semantic_max =
      Map.get(config, :semantic_cache_max_entries, @default_semantic_cache_max_entries)

    pruned_peer = prune_peer_stream(peer_stream_ttl, peer_stream_max)
    pruned_snapshots = prune_multipatch_snapshots(snapshot_ttl, snapshot_max)
    pruned_resilience = prune_resilience_breakers()
    pruned_terminals = prune_terminal_command_history(term_ttl)
    pruned_throttle = prune_admin_throttle()
    pruned_semantic = prune_semantic_cache(semantic_max)

    checkpoint_wal()

    total =
      pruned_peer + pruned_snapshots + pruned_resilience + pruned_terminals + pruned_throttle +
        pruned_semantic

    result = %{
      peer_stream: pruned_peer,
      multipatch_snapshots: pruned_snapshots,
      resilience_breakers: pruned_resilience,
      terminal_history: pruned_terminals,
      admin_throttle: pruned_throttle,
      semantic_cache: pruned_semantic,
      total_pruned: total,
      timestamp: DateTime.utc_now()
    }

    :telemetry.execute(
      [:iex_code, :ets_pruner, :sweep],
      %{total_pruned: total},
      result
    )

    result
  end

  @doc """
  Prunes PeerStream history: deletes messages older than TTL and enforces hard maximum entry count.
  """
  def prune_peer_stream(
        max_age_seconds \\ @default_peer_stream_ttl_seconds,
        max_entries \\ @default_peer_stream_max_entries
      ) do
    table = :iex_code_swarm_peer_stream_history

    case :ets.whereis(table) do
      :undefined ->
        0

      _tid ->
        now_dt = DateTime.utc_now()
        rows = :ets.tab2list(table)

        # 1. Single-pass split into expired and active entries
        {expired, active} =
          Enum.split_with(rows, fn {_swarm_id, _order_key, msg} ->
            case extract_timestamp(msg) do
              %DateTime{} = dt ->
                DateTime.diff(now_dt, dt, :second) > max_age_seconds

              _ ->
                false
            end
          end)

        Enum.each(expired, fn row ->
          :ets.delete_object(table, row)
        end)

        deleted_expired = length(expired)

        # 2. Capacity-based pruning (FIFO eviction if active size still exceeds max_entries)
        deleted_overflow =
          if length(active) > max_entries do
            overflow_count = length(active) - max_entries

            active
            |> Enum.sort_by(fn {_swarm_id, order_key, _msg} -> order_key end)
            |> Enum.take(overflow_count)
            |> Enum.each(fn row -> :ets.delete_object(table, row) end)

            overflow_count
          else
            0
          end

        deleted_expired + deleted_overflow
    end
  rescue
    _ -> 0
  end

  @doc """
  Prunes MultiPatch snapshot ETS cache: deletes snapshots older than TTL and enforces max count.
  (Authoritative snapshots remain safe in SQLite).
  """
  def prune_multipatch_snapshots(
        max_age_seconds \\ @default_snapshot_ttl_seconds,
        max_entries \\ @default_snapshot_max_entries
      ) do
    table = :iex_code_multipatch_snapshots

    case :ets.whereis(table) do
      :undefined ->
        0

      _tid ->
        now_dt = DateTime.utc_now()
        rows = :ets.tab2list(table)

        # 1. Single-pass split into expired and active entries
        {expired, active} =
          Enum.split_with(rows, fn {_tx_id, entry} ->
            case Map.get(entry, :timestamp) do
              %DateTime{} = dt ->
                DateTime.diff(now_dt, dt, :second) > max_age_seconds

              _ ->
                false
            end
          end)

        Enum.each(expired, fn {tx_id, _} ->
          :ets.delete(table, tx_id)
        end)

        deleted_expired = length(expired)

        # 2. Capacity eviction (FIFO)
        deleted_overflow =
          if length(active) > max_entries do
            overflow_count = length(active) - max_entries

            active
            |> Enum.sort_by(fn {_tx_id, entry} ->
              case Map.get(entry, :timestamp) do
                %DateTime{} = dt -> DateTime.to_unix(dt, :millisecond)
                _ -> 0
              end
            end)
            |> Enum.take(overflow_count)
            |> Enum.each(fn {tx_id, _} -> :ets.delete(table, tx_id) end)

            overflow_count
          else
            0
          end

        deleted_expired + deleted_overflow
    end
  rescue
    _ -> 0
  end

  @doc """
  Prunes the semantic vector cache (:iex_code_semantic_cache) if it exceeds maximum entry count.
  Cached embeddings can always be reloaded on-demand from the authoritative SQLite database.
  """
  def prune_semantic_cache(max_entries \\ @default_semantic_cache_max_entries) do
    table = :iex_code_semantic_cache

    case :ets.whereis(table) do
      :undefined ->
        0

      _tid ->
        size = :ets.info(table, :size)

        if is_integer(size) and size > max_entries do
          overflow = size - max_entries

          keys_to_evict =
            Stream.unfold(:ets.first(table), fn
              :"$end_of_table" -> nil
              key -> {key, :ets.next(table, key)}
            end)
            |> Enum.take(overflow)

          Enum.each(keys_to_evict, fn key -> :ets.delete(table, key) end)
          length(keys_to_evict)
        else
          0
        end
    end
  rescue
    _ -> 0
  end

  @doc """
  Prunes expired circuit breaker entries that have finished their cooldown.
  """
  def prune_resilience_breakers do
    table = IexCode.LLM.Resilience

    case :ets.whereis(table) do
      :undefined ->
        0

      _tid ->
        now_ms = System.monotonic_time(:millisecond)
        cooldown_ms = 30_000

        rows = :ets.tab2list(table)

        expired =
          Enum.filter(rows, fn
            {_provider, _failures, opened_at} when is_integer(opened_at) ->
              now_ms - opened_at >= cooldown_ms

            _ ->
              false
          end)

        Enum.each(expired, fn {provider, _f, _o} ->
          :ets.insert(table, {provider, 0, nil})
        end)

        length(expired)
    end
  rescue
    _ -> 0
  end

  @doc """
  Prunes terminal command history for terminated sessions or entries older than TTL.
  """
  def prune_terminal_command_history(max_age_ms \\ @default_terminal_history_ttl_ms) do
    table = :iex_code_terminal_command_history

    case :ets.whereis(table) do
      :undefined ->
        0

      _tid ->
        now_ms = System.monotonic_time(:millisecond)
        rows = :ets.tab2list(table)

        stale =
          Enum.filter(rows, fn
            {session_id, _history, updated_at} ->
              is_old? = is_integer(updated_at) and now_ms - updated_at > max_age_ms
              is_dead? = dead_terminal_session?(session_id)
              is_old? or is_dead?

            _ ->
              false
          end)

        Enum.each(stale, fn {session_id, _, _} ->
          :ets.delete(table, session_id)
        end)

        length(stale)
    end
  rescue
    _ -> 0
  end

  @doc """
  Prunes expired admin throttle rate-limit buckets older than 5 minutes.
  """
  def prune_admin_throttle do
    table = :iex_code_web_admin_auth_throttle

    case :ets.whereis(table) do
      :undefined ->
        0

      _tid ->
        current_bucket = div(System.monotonic_time(:second), 60)
        # Keep current and previous 2 buckets (up to 3 minutes history), prune anything older
        cutoff_bucket = current_bucket - 2

        match_spec = [
          {{{:"$1", :"$2"}, :"$3"}, [{:<, :"$2", cutoff_bucket}], [true]}
        ]

        :ets.select_delete(table, match_spec)
    end
  rescue
    _ -> 0
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp schedule_sweep(interval_ms) when is_integer(interval_ms) and interval_ms > 0 do
    Process.send_after(self(), :sweep, interval_ms)
  end

  defp schedule_sweep(_), do: nil

  defp extract_timestamp(msg) when is_map(msg) do
    Map.get(msg, :timestamp) || Map.get(msg, "timestamp")
  end

  defp extract_timestamp(_), do: nil

  defp dead_terminal_session?(session_id) when is_binary(session_id) do
    case Registry.lookup(IexCode.SessionRegistry, {:terminal, session_id}) do
      [{pid, _}] -> not Process.alive?(pid)
      [] -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp dead_terminal_session?(_), do: true

  defp resolve_pid(pid) when is_pid(pid) do
    if Process.alive?(pid), do: pid, else: nil
  end

  defp resolve_pid(name) when is_atom(name) do
    Process.whereis(name)
  end

  defp resolve_pid(_), do: nil

  defp checkpoint_wal do
    if Code.ensure_loaded?(IexCode.Repo) and function_exported?(IexCode.Repo, :checkpoint_wal, 0) do
      case IexCode.Repo.checkpoint_wal() do
        {:ok, _} ->
          :ok

        {:error, %DBConnection.OwnershipError{}} ->
          :ok

        {:error, reason} ->
          Logger.warning("[ETSPruner] Periodic SQLite WAL checkpoint failed: #{inspect(reason)}")
          :error
      end
    else
      :ok
    end
  rescue
    _ -> :ok
  end
end
