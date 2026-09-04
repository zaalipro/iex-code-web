defmodule IexCode.Observability.MemoryPollerTest do
  use ExUnit.Case, async: false

  alias IexCode.Observability.MemoryPoller
  alias IexCode.Observability.MemorySnapshot
  alias Phoenix.PubSub

  describe "MemorySnapshot struct and formatters" do
    test "new/1 initializes all required fields with defaults" do
      snapshot = MemorySnapshot.new()

      assert %MemorySnapshot{} = snapshot
      assert snapshot.rss_bytes == 0
      assert snapshot.beam_total_bytes == 0
      assert snapshot.beam_processes_bytes == 0
      assert snapshot.beam_system_bytes == 0
      assert snapshot.beam_atom_bytes == 0
      assert snapshot.beam_binary_bytes == 0
      assert snapshot.beam_ets_bytes == 0
      assert snapshot.process_count == 0
      assert snapshot.gc_runs == 0
      assert snapshot.gc_words_reclaimed == 0
      assert snapshot.delta_gc_runs == 0
      assert snapshot.delta_reclaimed_bytes == 0
      assert %DateTime{} = snapshot.timestamp
    end

    test "format_bytes/1 formats bytes into human-readable strings" do
      assert MemorySnapshot.format_bytes(0) == "0 B"
      assert MemorySnapshot.format_bytes(512) == "512 B"
      assert MemorySnapshot.format_bytes(1024) == "1.0 KB"
      assert MemorySnapshot.format_bytes(10_240) == "10.0 KB"
      assert MemorySnapshot.format_bytes(1_048_576) == "1.0 MB"
      assert MemorySnapshot.format_bytes(71_512_883) == "68.2 MB"
      assert MemorySnapshot.format_bytes(37_853_593) == "36.1 MB"
      assert MemorySnapshot.format_bytes(1_073_741_824) == "1.0 GB"
      assert MemorySnapshot.format_bytes(2_684_354_560) == "2.5 GB"
      assert MemorySnapshot.format_bytes(-100) == "0 B"
      assert MemorySnapshot.format_bytes(nil) == "0 B"
      assert MemorySnapshot.format_bytes(1_048_576.0) == "1.0 MB"
    end
  end

  describe "Direct Sampling" do
    test "sample_os_rss/0 returns non-negative integer on Unix/Darwin" do
      rss = MemoryPoller.sample_os_rss()
      assert is_integer(rss)
      assert rss >= 0

      # On macOS Darwin where `ps` is present, it returns real positive RSS
      if match?({:unix, :darwin}, :os.type()) do
        assert rss > 0
      end
    end

    test "sample_metrics/1 populates genuine BEAM and micro-GC statistics" do
      snapshot = MemoryPoller.sample_metrics(nil)

      assert %MemorySnapshot{} = snapshot
      assert snapshot.beam_total_bytes > 0
      assert snapshot.beam_processes_bytes > 0
      assert snapshot.beam_system_bytes > 0
      assert snapshot.beam_atom_bytes > 0
      assert snapshot.beam_binary_bytes >= 0
      assert snapshot.beam_ets_bytes >= 0
      assert snapshot.process_count > 0
      assert snapshot.gc_runs >= 0
      assert snapshot.gc_words_reclaimed >= 0
      assert snapshot.delta_gc_runs == 0
      assert snapshot.delta_reclaimed_bytes == 0
      assert %DateTime{} = snapshot.timestamp
    end

    test "sample_metrics/1 computes micro-GC deltas correctly with previous sample" do
      first = MemoryPoller.sample_metrics(nil)

      synthetic_prev = %MemorySnapshot{
        first
        | gc_runs: max(0, first.gc_runs - 4),
          gc_words_reclaimed: max(0, first.gc_words_reclaimed - 200)
      }

      second = MemoryPoller.sample_metrics(synthetic_prev)

      assert second.delta_gc_runs >= 4
      assert second.delta_reclaimed_bytes >= 200 * :erlang.system_info(:wordsize)
    end
  end

  describe "Client API and GenServer" do
    test "current_metrics/0 returns a valid snapshot from supervised server or direct sample" do
      snapshot = MemoryPoller.current_metrics()

      assert %MemorySnapshot{} = snapshot
      assert snapshot.beam_total_bytes > 0
      assert snapshot.process_count > 0
    end

    test "sample_now/1 with snapshot returns a fresh sample with deltas" do
      prev = MemoryPoller.sample_metrics(nil)
      next_snap = MemoryPoller.sample_now(prev)

      assert %MemorySnapshot{} = next_snap
      assert next_snap.beam_total_bytes > 0
    end

    test "isolated MemoryPoller GenServer handles :tick and broadcasts to PubSub" do
      PubSub.subscribe(IexCode.PubSub, "telemetry:memory")

      poller =
        start_supervised!({
          MemoryPoller,
          name: :test_memory_poller, enabled: false, pubsub_server: IexCode.PubSub
        })

      # Trigger tick
      send(poller, :tick)

      assert_receive {:memory_telemetry, %MemorySnapshot{} = broadcast_snapshot}, 2000
      assert broadcast_snapshot.beam_total_bytes > 0
      assert broadcast_snapshot.process_count > 0

      # Check current metrics returns this sample
      metrics = MemoryPoller.current_metrics(:test_memory_poller)
      assert metrics.beam_total_bytes == broadcast_snapshot.beam_total_bytes
    end

    test "force_gc/1 runs garbage collection and broadcasts immediately" do
      PubSub.subscribe(IexCode.PubSub, "telemetry:memory")

      snapshot = MemoryPoller.force_gc()

      assert %MemorySnapshot{} = snapshot
      assert_receive {:memory_telemetry, %MemorySnapshot{}}, 2000
    end

    test "sample_now/1 on server pid updates snapshot and broadcasts" do
      PubSub.subscribe(IexCode.PubSub, "telemetry:memory")

      poller =
        start_supervised!({
          MemoryPoller,
          name: :test_sample_now_poller, enabled: false, pubsub_server: IexCode.PubSub
        })

      snapshot = MemoryPoller.sample_now(poller)

      assert %MemorySnapshot{} = snapshot
      assert_receive {:memory_telemetry, %MemorySnapshot{}}, 2000
    end
  end
end
