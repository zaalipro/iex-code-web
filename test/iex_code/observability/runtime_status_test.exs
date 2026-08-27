defmodule IexCode.Observability.RuntimeStatusTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias IexCode.Observability.RuntimeStatus

  test "snapshot reports an idle bounded runtime and ignores dormant terminals for activity" do
    cgroup_root = cgroup_fixture("268435456", "1073741824")

    snapshot =
      RuntimeStatus.snapshot(
        cgroup_root: cgroup_root,
        dispatcher_stats: fn -> %{active: 0, queued: 0, capacity: 2} end,
        metrics_snapshot: fn ->
          %{
            control_plane: %{
              runs_active: 0,
              runs_queued: 0,
              agents_active: 0,
              agents_paused: 0,
              dag_attempts_active: 0
            }
          }
        end,
        supervisor_count: &idle_supervisor_counts/1,
        beam_memory: fn -> 134_217_728 end,
        beam_system_info: fn
          :port_count -> 7
          :port_limit -> 65_536
        end
      )

    assert snapshot == %{
             state: :idle,
             container: %{
               memory_current_bytes: 268_435_456,
               memory_limit_bytes: 1_073_741_824
             },
             beam: %{
               memory_total_bytes: 134_217_728,
               port_count: 7,
               port_limit: 65_536
             },
             dispatcher: %{active: 0, queued: 0, capacity: 2},
             activity: %{
               agents: 0,
               fleets: 0,
               sessions: 3,
               terminals: 2,
               dag_attempts: 0
             }
           }
  end

  test "paused durable agents and active DAG attempts make the runtime active" do
    snapshot =
      RuntimeStatus.snapshot(
        cgroup_root: cgroup_fixture("0", "max"),
        dispatcher_stats: fn -> %{active: 0, queued: 0, capacity: 4} end,
        metrics_snapshot: fn ->
          %{
            control_plane: %{
              runs_active: 0,
              runs_queued: 0,
              agents_active: 1,
              agents_paused: 2,
              dag_attempts_active: 1
            }
          }
        end,
        supervisor_count: fn _supervisor -> %{active: 0} end,
        beam_memory: fn -> 0 end,
        beam_system_info: fn _key -> 0 end
      )

    assert snapshot.state == :active
    assert snapshot.activity.agents == 3
    assert snapshot.activity.dag_attempts == 1
    assert snapshot.container.memory_limit_bytes == :unlimited
  end

  test "legacy agents and fleets are included without exposing supervisor details" do
    snapshot =
      RuntimeStatus.snapshot(
        cgroup_root: cgroup_fixture("1024", "2048"),
        dispatcher_stats: fn -> %{active: 0, queued: 0, capacity: 1} end,
        metrics_snapshot: fn -> zero_control_plane() end,
        supervisor_count: fn
          IexCode.Engine.AgentSupervisor -> %{active: 2, workers: 2, specs: 2}
          IexCode.Engine.FleetSupervisor -> %{active: 1, workers: 0, supervisors: 1}
          _supervisor -> %{active: 0}
        end,
        beam_memory: fn -> 1024 end,
        beam_system_info: fn _key -> 1 end
      )

    assert snapshot.state == :active
    assert snapshot.activity.agents == 2
    assert snapshot.activity.fleets == 1
    assert Map.keys(snapshot.dispatcher) |> Enum.sort() == [:active, :capacity, :queued]
  end

  test "missing or failing dependencies return unavailable measurements instead of crashing" do
    root = Path.join(System.tmp_dir!(), "runtime-status-missing-#{System.unique_integer()}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    snapshot =
      RuntimeStatus.snapshot(
        cgroup_root: root,
        dispatcher_stats: fn -> exit(:restarting) end,
        metrics_snapshot: fn -> raise "database unavailable" end,
        supervisor_count: fn _supervisor -> throw(:restarting) end,
        beam_memory: fn -> :invalid end,
        beam_system_info: fn _key -> exit(:not_running) end
      )

    assert snapshot.state == :unavailable
    assert snapshot.container == %{memory_current_bytes: nil, memory_limit_bytes: nil}
    assert snapshot.beam == %{memory_total_bytes: nil, port_count: nil, port_limit: nil}
    assert snapshot.dispatcher == %{active: nil, queued: nil, capacity: nil}

    assert snapshot.activity == %{
             agents: nil,
             fleets: nil,
             sessions: nil,
             terminals: nil,
             dag_attempts: nil
           }
  end

  test "a known active source wins over temporarily unavailable measurements" do
    snapshot =
      RuntimeStatus.snapshot(
        cgroup_root: cgroup_fixture("invalid", "-1"),
        dispatcher_stats: fn -> %{active: 1, queued: 0, capacity: 0} end,
        metrics_snapshot: fn -> nil end,
        supervisor_count: fn _supervisor -> raise "restarting" end,
        beam_memory: fn -> 100 end,
        beam_system_info: fn _key -> 10 end
      )

    assert snapshot.state == :active
    assert snapshot.container.memory_current_bytes == nil
    assert snapshot.container.memory_limit_bytes == nil
  end

  test "snapshot has a bounded timeout when a runtime dependency never replies" do
    started_at = System.monotonic_time(:millisecond)

    snapshot =
      RuntimeStatus.snapshot(
        snapshot_timeout_ms: 20,
        dispatcher_stats: fn ->
          receive do
            :never -> %{}
          end
        end
      )

    elapsed = System.monotonic_time(:millisecond) - started_at

    assert snapshot.state == :unavailable
    assert snapshot.dispatcher == %{active: nil, queued: nil, capacity: nil}
    assert elapsed < 500
  end

  test "format_cli emits stable aggregate-only output" do
    snapshot = %{
      state: :idle,
      container: %{memory_current_bytes: 268_435_456, memory_limit_bytes: 1_073_741_824},
      beam: %{memory_total_bytes: 134_217_728, port_count: 7, port_limit: 65_536},
      dispatcher: %{active: 0, queued: 0, capacity: 2},
      activity: %{agents: 0, fleets: 0, sessions: 3, terminals: 2, dag_attempts: 0}
    }

    assert RuntimeStatus.format_cli(snapshot) == [
             "IexCode runtime: idle",
             "Container memory: 256.0 MiB / 1.0 GiB",
             "BEAM memory: 128.0 MiB",
             "BEAM ports: 7 / 65536",
             "Runs: 0 active, 0 queued, 2 capacity",
             "Agents: 0 active",
             "Fleets: 0 active",
             "DAG attempts: 0 active",
             "Sessions: 3",
             "Terminals: 2"
           ]
  end

  test "format_cli tolerates a partial snapshot" do
    assert RuntimeStatus.format_cli(%{state: :unavailable}) == [
             "IexCode runtime: unavailable",
             "Container memory: unavailable / unavailable",
             "BEAM memory: unavailable",
             "BEAM ports: unavailable / unavailable",
             "Runs: unavailable active, unavailable queued, unavailable capacity",
             "Agents: unavailable active",
             "Fleets: unavailable active",
             "DAG attempts: unavailable active",
             "Sessions: unavailable",
             "Terminals: unavailable"
           ]
  end

  test "print_cli prints the current aggregate snapshot" do
    output = capture_io(&RuntimeStatus.print_cli/0)

    assert output =~ "IexCode runtime:"
    assert output =~ "Container memory:"
    assert output =~ "BEAM ports:"
    refute output =~ "worker_id"
    refute output =~ "lease_owner"
  end

  defp idle_supervisor_counts(IexCode.Engine.SessionSupervisor), do: %{active: 3}
  defp idle_supervisor_counts(IexCode.Tools.TerminalSupervisor), do: %{active: 2}
  defp idle_supervisor_counts(_supervisor), do: %{active: 0}

  defp zero_control_plane do
    %{
      control_plane: %{
        runs_active: 0,
        runs_queued: 0,
        agents_active: 0,
        agents_paused: 0,
        dag_attempts_active: 0
      }
    }
  end

  defp cgroup_fixture(current, maximum) do
    root = Path.join(System.tmp_dir!(), "runtime-status-#{System.unique_integer()}")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "memory.current"), current <> "\n")
    File.write!(Path.join(root, "memory.max"), maximum <> "\n")
    on_exit(fn -> File.rm_rf(root) end)
    root
  end
end
