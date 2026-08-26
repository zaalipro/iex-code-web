defmodule IexCodeWeb.TelemetryTest do
  use IexCode.DataCase, async: false

  alias IexCodeWeb.Telemetry
  alias IexCode.Observability.{ControlPlaneSnapshot, MetricsStore}

  @snapshot_event [:iex_code, :control_plane, :snapshot]
  @snapshot_measurements ~w(
    runs_queued
    runs_active
    runs_attention
    runs_expired_leases
    agents_active
    agents_paused
    agents_attention
    agents_expired_leases
    dag_attempts_active
    dag_attempts_expired_leases
    run_controls_open
    agent_controls_open
    approvals_pending
    approvals_overdue
    workspace_locks_held
    workspace_locks_waiting
    workspace_locks_expired
  )a

  test "test environment disables the supervised database poller without disabling direct sampling" do
    assert Telemetry.poller_child_spec() == nil
    assert Supervisor.which_children(Telemetry) == []

    assert {:telemetry_poller, opts} =
             Telemetry.poller_child_spec(enabled: true, period: 1_234, init_delay: 25)

    assert opts[:period] == 1_234
    assert opts[:init_delay] == 25
    assert opts[:measurements] == [{Telemetry, :measure_control_plane, []}]
  end

  test "defines operation metrics for every emitted lifecycle event" do
    metrics = Telemetry.metrics()

    assert metric!(metrics, [:iex_code, :operation, :started, :total]).event_name ==
             [:iex_code, :operation, :start]

    assert metric!(metrics, [:iex_code, :operation, :started, :total]).measurement.(%{
             system_time: 123
           }) == 1

    assert metric!(metrics, [:iex_code, :operation, :progress, :percent]).event_name ==
             [:iex_code, :operation, :progress]

    assert metric!(metrics, [:iex_code, :operation, :completed, :total]).event_name ==
             [:iex_code, :operation, :stop]

    assert metric!(metrics, [:iex_code, :operation, :failed, :total]).event_name ==
             [:iex_code, :operation, :crash]

    duration = metric!(metrics, [:iex_code, :operation, :completed, :duration])
    assert duration.measurement == :duration_ms
    assert duration.unit == :millisecond
    assert duration.tags == [:operation_class]

    assert duration.tag_values.(%{op_type: "read_file", session_id: "private"}) == %{
             operation_class: "filesystem"
           }

    assert duration.tag_values.(%{op_type: "tenant-defined-operation"}) == %{
             operation_class: "other"
           }
  end

  test "terminal duration metrics preserve millisecond measurements and bound tag values" do
    metrics = Telemetry.metrics()
    duration = metric!(metrics, [:iex_code, :terminal, :command_completed, :duration])
    stopped = metric!(metrics, [:iex_code, :terminal, :session_stopped, :duration])
    started = metric!(metrics, [:iex_code, :terminal, :session_started, :total])

    assert duration.measurement == :duration_ms
    assert duration.unit == :millisecond
    assert duration.tags == [:status, :agent_class]

    assert duration.tag_values.(%{
             status: :ok,
             agent_name: "ExplorerAgent",
             session_id: "must-not-be-a-tag"
           }) == %{status: "ok", agent_class: "explorer"}

    assert stopped.measurement == :duration_ms
    assert stopped.unit == :millisecond
    assert stopped.tags == [:reason_class]

    assert stopped.tag_values.(%{reason: {:sensitive_reason, "details"}}) == %{
             reason_class: "other"
           }

    assert started.tag_values.(%{shell: "/private/custom-shell"}) == %{shell_family: "other"}
  end

  test "metric definitions contain no durable or session identifier tags" do
    metrics = Telemetry.metrics()
    forbidden = MapSet.new(~w(session_id run_id operation_id agent_id command_id)a)

    assert length(metrics) == metrics |> Enum.map(& &1.name) |> Enum.uniq() |> length()

    for metric <- metrics do
      assert MapSet.disjoint?(MapSet.new(metric.tags), forbidden),
             "#{Enum.join(metric.name, ".")} contains an unbounded identifier tag"
    end
  end

  test "fleet rehydration failures are counted without identifier or reason tags" do
    metric = metric!(Telemetry.metrics(), [:iex_code, :fleet, :rehydrate_error, :total])

    assert metric.event_name == [:iex_code, :fleet, :rehydrate_error]
    assert metric.tags == []
    assert metric.measurement.(%{count: 1}) == 1
  end

  test "every counter uses a reporter-compatible measurement" do
    for metric <- Telemetry.metrics(), metric.__struct__ == Telemetry.Metrics.Counter do
      assert is_function(metric.measurement, 1)
      assert metric.measurement.(%{}) == 1
    end
  end

  test "control-plane gauges are tag-free and cover each durable subsystem" do
    metrics = Telemetry.metrics()

    for measurement <- @snapshot_measurements do
      metric = metric!(metrics, [:iex_code, :control_plane, :snapshot, measurement])
      assert metric.event_name == @snapshot_event
      assert metric.measurement == measurement
      assert metric.tags == []
    end
  end

  test "periodic control-plane measurement emits a bounded aggregate snapshot" do
    handler_id = "control-plane-snapshot-test-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        @snapshot_event,
        fn event, measurements, metadata, _config ->
          send(test_pid, {:snapshot, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert :ok = Telemetry.measure_control_plane()

    assert_receive {:snapshot, @snapshot_event, measurements, %{}}, 1_000
    assert Map.keys(measurements) |> Enum.sort() == Enum.sort(@snapshot_measurements)
    assert Enum.all?(measurements, fn {_name, value} -> is_integer(value) and value >= 0 end)
  end

  test "control-plane snapshot reflects durable run status changes" do
    before = ControlPlaneSnapshot.build()
    root = Path.join(System.tmp_dir!(), "telemetry-snapshot-#{Ecto.UUID.generate()}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    {:ok, project} = IexCode.Projects.create_project(%{name: "Telemetry", root_path: root})

    {:ok, session} =
      IexCode.Sessions.create_session(%{
        project_id: project.id,
        title: "Telemetry",
        status: "idle"
      })

    {:ok, run} =
      IexCode.Runs.create_run(%{
        project_id: project.id,
        session_id: session.id,
        objective: "Observe this durable run",
        kind: "analysis",
        mode: "workflow"
      })

    queued = ControlPlaneSnapshot.build()
    assert queued.runs_queued == before.runs_queued + 1

    {:ok, _failed} = IexCode.Runs.transition_run(run, "failed")
    failed = ControlPlaneSnapshot.build()
    assert failed.runs_queued == before.runs_queued
    assert failed.runs_attention == before.runs_attention + 1
  end

  test "control-plane snapshot evaluates active lease expiry against the supplied instant" do
    before = ControlPlaneSnapshot.build()
    root = Path.join(System.tmp_dir!(), "telemetry-lease-#{Ecto.UUID.generate()}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    {:ok, project} = IexCode.Projects.create_project(%{name: "Lease telemetry", root_path: root})

    {:ok, session} =
      IexCode.Sessions.create_session(%{
        project_id: project.id,
        title: "Lease telemetry",
        status: "idle"
      })

    {:ok, _run} =
      IexCode.Runs.create_run(%{
        project_id: project.id,
        session_id: session.id,
        objective: "Observe lease expiry",
        kind: "analysis",
        mode: "workflow"
      })

    owner = String.duplicate("a", 64)
    {:ok, claimed} = IexCode.Runs.claim_next_run(owner, lease_ms: 5_000)
    before_expiry = ControlPlaneSnapshot.build(claimed.heartbeat_at)
    after_expiry = ControlPlaneSnapshot.build(DateTime.add(claimed.lease_expires_at, 1, :second))

    assert before_expiry.runs_active == before.runs_active + 1
    assert before_expiry.runs_expired_leases == before.runs_expired_leases
    assert after_expiry.runs_expired_leases == before.runs_expired_leases + 1
  end

  test "metrics store retains bounded counters and the latest control snapshot" do
    name = Module.concat(__MODULE__, "Store#{System.unique_integer([:positive])}")
    start_supervised!({MetricsStore, name: name})

    :telemetry.execute([:iex_code, :operation, :start], %{system_time: 1}, %{op_type: "read_file"})

    :telemetry.execute(
      [:iex_code, :fleet, :rehydrate_error],
      %{count: 1},
      %{run_id: "not-retained", agent_id: "not-retained"}
    )

    :telemetry.execute(
      @snapshot_event,
      %{runs_queued: 2, runs_active: 1, attacker_controlled_key: 999},
      %{}
    )

    _ = :sys.get_state(name)

    snapshot = MetricsStore.snapshot(name)
    assert snapshot.counters["operation.start"] == 1
    assert snapshot.counters["fleet.rehydrate_error"] == 1
    assert Map.keys(snapshot.control_plane) |> Enum.sort() == Enum.sort(@snapshot_measurements)
    assert snapshot.control_plane.runs_active == 1
    assert snapshot.control_plane.runs_queued == 2
    assert snapshot.control_plane.approvals_pending == 0
    refute Map.has_key?(snapshot.control_plane, :attacker_controlled_key)
    assert %DateTime{} = snapshot.last_snapshot_at
  end

  test "metrics store replaces a stale telemetry handler after supervised restart" do
    name = Module.concat(__MODULE__, "RestartingStore#{System.unique_integer([:positive])}")
    pid = start_supervised!({MetricsStore, name: name})
    ref = Process.monitor(pid)

    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

    replacement = wait_for_registered_process(name)
    refute replacement == pid
    _ = :sys.get_state(replacement)

    handlers =
      @snapshot_event
      |> :telemetry.list_handlers()
      |> Enum.filter(&(&1.id == {MetricsStore, name}))

    assert length(handlers) == 1
  end

  test "metrics store counts snapshot collection failures" do
    name = Module.concat(__MODULE__, "FailingStore#{System.unique_integer([:positive])}")
    start_supervised!({MetricsStore, name: name})

    :telemetry.execute([:iex_code, :control_plane, :snapshot_error], %{count: 1}, %{})
    _ = :sys.get_state(name)

    assert MetricsStore.snapshot(name).snapshot_errors == 1
  end

  defp metric!(metrics, name) do
    Enum.find(metrics, &(&1.name == name)) || flunk("missing metric #{Enum.join(name, ".")}")
  end

  defp wait_for_registered_process(name, attempts \\ 50)

  defp wait_for_registered_process(_name, 0), do: flunk("metrics store did not restart")

  defp wait_for_registered_process(name, attempts) do
    case Process.whereis(name) do
      pid when is_pid(pid) ->
        pid

      nil ->
        receive do
        after
          10 -> wait_for_registered_process(name, attempts - 1)
        end
    end
  end
end
