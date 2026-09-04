defmodule IexCode.Observability.ETSPrunerTest do
  use ExUnit.Case, async: false

  alias IexCode.Observability.ETSPruner

  setup do
    # Ensure tables exist
    ensure_table(:iex_code_swarm_peer_stream_history, [:duplicate_bag, :public, :named_table])
    ensure_table(:iex_code_multipatch_snapshots, [:set, :public, :named_table])
    ensure_table(IexCode.LLM.Resilience, [:set, :public, :named_table])
    ensure_table(:iex_code_terminal_command_history, [:set, :public, :named_table])
    ensure_table(:iex_code_web_admin_auth_throttle, [:set, :public, :named_table])
    ensure_table(:iex_code_semantic_cache, [:set, :public, :named_table])

    # Clean up managed tables
    :ets.delete_all_objects(:iex_code_swarm_peer_stream_history)
    :ets.delete_all_objects(:iex_code_multipatch_snapshots)
    :ets.delete_all_objects(IexCode.LLM.Resilience)
    :ets.delete_all_objects(:iex_code_terminal_command_history)
    :ets.delete_all_objects(:iex_code_web_admin_auth_throttle)
    :ets.delete_all_objects(:iex_code_semantic_cache)

    :ok
  end

  describe "table_stats/0" do
    test "returns presence and memory stats for all managed tables" do
      stats = ETSPruner.table_stats()
      assert is_map(stats)
      assert Map.has_key?(stats, :iex_code_swarm_peer_stream_history)
      assert Map.has_key?(stats, :iex_code_multipatch_snapshots)
      assert Map.has_key?(stats, IexCode.LLM.Resilience)
      assert Map.has_key?(stats, :iex_code_terminal_command_history)
      assert Map.has_key?(stats, :iex_code_web_admin_auth_throttle)
      assert Map.has_key?(stats, :iex_code_semantic_cache)

      peer_stats = stats[:iex_code_swarm_peer_stream_history]
      assert peer_stats.exists? == true
      assert peer_stats.size == 0
      assert is_integer(peer_stats.memory_bytes)
    end
  end

  describe "prune_peer_stream/2" do
    test "evicts messages older than TTL and preserves fresh ones" do
      table = :iex_code_swarm_peer_stream_history
      now = DateTime.utc_now()
      old_dt = DateTime.add(now, -3600, :second)
      fresh_dt = DateTime.add(now, -60, :second)

      old_msg = %{id: "m-old", timestamp: old_dt, content: "old message"}
      fresh_msg = %{id: "m-fresh", timestamp: fresh_dt, content: "fresh message"}

      :ets.insert(table, {"swarm-1", 100, old_msg})
      :ets.insert(table, {"swarm-1", 200, fresh_msg})

      assert :ets.info(table, :size) == 2

      # TTL = 1800s (30m)
      deleted = ETSPruner.prune_peer_stream(1800, 5000)
      assert deleted == 1
      assert :ets.info(table, :size) == 1

      remaining = :ets.tab2list(table)
      assert [{_, _, %{id: "m-fresh"}}] = remaining
    end

    test "enforces max_entries cap via FIFO eviction" do
      table = :iex_code_swarm_peer_stream_history
      now = DateTime.utc_now()

      for i <- 1..10 do
        msg = %{id: "m-#{i}", timestamp: now}
        :ets.insert(table, {"swarm-1", i, msg})
      end

      assert :ets.info(table, :size) == 10

      # Limit to 5 entries
      deleted = ETSPruner.prune_peer_stream(3600, 5)
      assert deleted == 5
      assert :ets.info(table, :size) == 5

      remaining = :ets.tab2list(table)
      remaining_ids = Enum.map(remaining, fn {_, _, %{id: id}} -> id end)
      assert remaining_ids == ["m-6", "m-7", "m-8", "m-9", "m-10"]
    end
  end

  describe "prune_multipatch_snapshots/2" do
    test "evicts in-memory snapshots older than TTL" do
      table = :iex_code_multipatch_snapshots
      now = DateTime.utc_now()
      old_dt = DateTime.add(now, -8000, :second)
      fresh_dt = DateTime.add(now, -60, :second)

      :ets.insert(table, {"tx-old", %{timestamp: old_dt, patches: []}})
      :ets.insert(table, {"tx-fresh", %{timestamp: fresh_dt, patches: []}})

      assert :ets.info(table, :size) == 2

      # TTL = 7200s (2 hours)
      deleted = ETSPruner.prune_multipatch_snapshots(7200, 1000)
      assert deleted == 1
      assert :ets.info(table, :size) == 1

      assert [{"tx-fresh", _}] = :ets.tab2list(table)
    end

    test "enforces max_entries cap on snapshots" do
      table = :iex_code_multipatch_snapshots
      now = DateTime.utc_now()

      for i <- 1..10 do
        dt = DateTime.add(now, i, :second)
        :ets.insert(table, {"tx-#{i}", %{timestamp: dt, patches: []}})
      end

      assert :ets.info(table, :size) == 10

      deleted = ETSPruner.prune_multipatch_snapshots(36000, 4)
      assert deleted == 6
      assert :ets.info(table, :size) == 4
    end
  end

  describe "prune_resilience_breakers/0" do
    test "resets cooldown for expired circuit breakers" do
      table = IexCode.LLM.Resilience
      now_ms = System.monotonic_time(:millisecond)

      # Expired cooldown (>30s ago)
      :ets.insert(table, {:provider_a, 3, now_ms - 40_000})
      # Active cooldown (<30s ago)
      :ets.insert(table, {:provider_b, 3, now_ms - 10_000})

      pruned = ETSPruner.prune_resilience_breakers()
      assert pruned == 1

      assert [{:provider_a, 0, nil}] = :ets.lookup(table, :provider_a)
      assert [{:provider_b, 3, _}] = :ets.lookup(table, :provider_b)
    end
  end

  describe "prune_admin_throttle/0" do
    test "prunes rate-limit buckets older than cutoff" do
      table = :iex_code_web_admin_auth_throttle
      current_bucket = div(System.monotonic_time(:second), 60)

      # Stale bucket (10 minutes ago)
      :ets.insert(table, {{"127.0.0.1", current_bucket - 10}, 3})
      # Current bucket
      :ets.insert(table, {{"127.0.0.1", current_bucket}, 1})

      assert :ets.info(table, :size) == 2

      pruned = ETSPruner.prune_admin_throttle()
      assert pruned == 1
      assert :ets.info(table, :size) == 1

      assert [{{"127.0.0.1", ^current_bucket}, 1}] = :ets.tab2list(table)
    end
  end

  describe "prune_semantic_cache/1" do
    test "enforces max_entries cap via key eviction" do
      table = :iex_code_semantic_cache

      for i <- 1..10 do
        :ets.insert(
          table,
          {"entry-#{i}", "proj-1", "file-#{i}", 1, 10, "sym", "def", "content", <<0>>}
        )
      end

      assert :ets.info(table, :size) == 10

      pruned = ETSPruner.prune_semantic_cache(5)
      assert pruned == 5
      assert :ets.info(table, :size) == 5
    end
  end

  describe "prune_all/0" do
    test "sweeps all tables synchronously and returns detailed summary" do
      res = ETSPruner.prune_all()
      assert is_map(res)
      assert Map.has_key?(res, :peer_stream)
      assert Map.has_key?(res, :multipatch_snapshots)
      assert Map.has_key?(res, :resilience_breakers)
      assert Map.has_key?(res, :terminal_history)
      assert Map.has_key?(res, :admin_throttle)
      assert Map.has_key?(res, :semantic_cache)
      assert Map.has_key?(res, :total_pruned)
      assert %DateTime{} = res.timestamp
    end
  end

  defp ensure_table(name, opts) do
    if :ets.info(name) == :undefined do
      try do
        :ets.new(name, opts)
      rescue
        ArgumentError -> :ok
      end
    end
  end
end
