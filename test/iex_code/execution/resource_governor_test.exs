defmodule IexCode.Execution.ResourceGovernorTest do
  use ExUnit.Case, async: true

  alias IexCode.Execution.ResourceGovernor
  alias IexCode.Execution.ResourcePermitSupervisor

  @mib 1_048_576

  setup do
    supervisor = start_supervised!(Task.Supervisor)
    %{task_supervisor: supervisor}
  end

  test "publishes the fixed default weights" do
    assert ResourceGovernor.default_class_weights() == %{
             llm_provider: 32 * @mib,
             ast_scan: 32 * @mib,
             research_fetch: 48 * @mib,
             dag_step: 64 * @mib,
             native_command: 128 * @mib,
             build_test: 512 * @mib
           }
  end

  test "validated policy updates apply live without releasing active tickets" do
    server = start_governor(memory(100, 2_048), headroom_bytes: 0)
    assert {:ok, ticket} = ResourceGovernor.request(:native_command, server: server)

    assert :ok =
             ResourceGovernor.update_policy(%{pressure_percent: 72, critical_percent: 88}, server)

    assert ResourceGovernor.snapshot(server).reserved_bytes == 128 * @mib

    assert {:error, :invalid_policy} =
             ResourceGovernor.update_policy(%{pressure_percent: 90, critical_percent: 85}, server)

    assert :ok = ResourceGovernor.release(ticket, server)
  end

  test "admits normal work and reports only aggregate reservations" do
    server = start_governor(memory(100, 1_000), headroom_bytes: 0)

    assert {:ok, ticket} = ResourceGovernor.request(:native_command, server: server)

    assert %{
             state: :normal,
             memory_current_bytes: current,
             memory_limit_bytes: limit,
             reserved_bytes: reserved,
             active_by_class: %{native_command: 1},
             queued_interactive: 0,
             queued_background: 0
           } = ResourceGovernor.snapshot(server)

    assert current == 100 * @mib
    assert limit == 1_000 * @mib
    assert reserved == 128 * @mib
    assert :ok = ResourceGovernor.release(ticket, server)
    assert ResourceGovernor.snapshot(server).reserved_bytes == 0
  end

  test "compact headroom does not subtract twice from the critical ceiling" do
    server = start_governor(memory(1_400, 2_500), profile: :compact)

    assert {:ok, ticket} = ResourceGovernor.request(:build_test, server: server)
    assert ResourceGovernor.snapshot(server).reserved_bytes == 512 * @mib
    assert :ok = ResourceGovernor.release(ticket, server)
  end

  test "compact profile admits one build at a realistic idle footprint" do
    server = start_governor(memory(267, 1_024), profile: :compact)

    assert {:ok, ticket} =
             ResourceGovernor.request(:build_test,
               server: server,
               priority: :background,
               run_key: :compact_build,
               timeout: 0
             )

    assert ResourceGovernor.snapshot(server).reserved_bytes == 512 * @mib
    assert :ok = ResourceGovernor.release(ticket, server)
  end

  test "queues weighted work under pressure and returns a capacity timeout", %{
    task_supervisor: task_supervisor
  } do
    server = start_governor(memory(710, 1_000), headroom_bytes: 0)
    parent = self()

    {:ok, _pid} =
      Task.Supervisor.start_child(task_supervisor, fn ->
        send(
          parent,
          {:request_result, ResourceGovernor.request(:llm_provider, server: server, timeout: 0)}
        )
      end)

    assert_receive {:request_result, {:error, :capacity_timeout}}
    assert %{state: :pressure, queued_background: 0} = ResourceGovernor.snapshot(server)
  end

  test "reports critical and unavailable memory states" do
    critical = start_governor(memory(850, 1_000), headroom_bytes: 0)
    unavailable = start_governor(fn -> %{memory_current_bytes: nil, memory_limit_bytes: nil} end)

    assert ResourceGovernor.snapshot(critical).state == :critical
    assert ResourceGovernor.snapshot(unavailable).state == :unavailable
  end

  test "with_permit releases after success and exception" do
    server = start_governor(memory(0, 1_000), headroom_bytes: 0)

    assert :worked ==
             ResourceGovernor.with_permit(:dag_step, [server: server], fn -> :worked end)

    assert ResourceGovernor.snapshot(server).reserved_bytes == 0

    assert_raise RuntimeError, "boom", fn ->
      ResourceGovernor.with_permit(:dag_step, [server: server], fn -> raise "boom" end)
    end

    assert ResourceGovernor.snapshot(server).reserved_bytes == 0
  end

  test "interactive FIFO precedes background run round-robin", %{
    task_supervisor: task_supervisor
  } do
    server = start_governor(memory(0, 1_000), headroom_bytes: 0)
    assert {:ok, blocker} = ResourceGovernor.request(:build_test, server: server)

    a1 = start_waiter(task_supervisor, server, :a1, :background, :run_a)
    await_queue(server, 0, 1)
    a2 = start_waiter(task_supervisor, server, :a2, :background, :run_a)
    await_queue(server, 0, 2)
    b1 = start_waiter(task_supervisor, server, :b1, :background, :run_b)
    await_queue(server, 0, 3)
    i1 = start_waiter(task_supervisor, server, :i1, :interactive, :interactive_one)
    await_queue(server, 1, 3)
    i2 = start_waiter(task_supervisor, server, :i2, :interactive, :interactive_two)
    await_queue(server, 2, 3)
    workers = [a1, a2, b1, i1, i2]
    assert :ok = ResourceGovernor.release(blocker, server)

    Enum.each([:i1, :i2, :a1, :b1, :a2], fn expected ->
      assert_receive {:granted, ^expected, pid, ticket}
      send(pid, {:release, ticket})
      assert_receive {:released, ^expected}
    end)

    Enum.each(workers, fn pid ->
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, reason}
      assert reason in [:normal, :noproc]
    end)

    assert ResourceGovernor.snapshot(server).reserved_bytes == 0
  end

  test "background work preserves profile capacity for an interactive request", %{
    task_supervisor: task_supervisor
  } do
    server =
      start_governor(memory(660, 1_000),
        headroom_bytes: 0,
        interactive_reserve_bytes: 64 * @mib,
        class_weights: %{build_test: 160 * @mib}
      )

    background = start_waiter(task_supervisor, server, :background, :background, :run_a)
    await_queue(server, 0, 1)

    assert {:ok, interactive} =
             ResourceGovernor.request(:llm_provider,
               server: server,
               priority: :interactive,
               run_key: :interactive
             )

    assert :ok = ResourceGovernor.release(interactive, server)
    assert ResourceGovernor.snapshot(server).queued_background == 1
    assert :ok = Task.Supervisor.terminate_child(task_supervisor, background)
    _ = :sys.get_state(server)
    assert ResourceGovernor.snapshot(server).queued_background == 0
  end

  test "an oversized background request does not block a smaller run", %{
    task_supervisor: task_supervisor
  } do
    server = start_governor(memory(500, 1_000), headroom_bytes: 0)

    oversized =
      start_waiter(task_supervisor, server, :oversized, :background, :run_a, :build_test)

    await_queue(server, 0, 1)

    smaller = start_waiter(task_supervisor, server, :smaller, :background, :run_b, :llm_provider)
    await_pending_count(server, 2)
    _ = ResourceGovernor.snapshot(server)

    assert_receive {:granted, :smaller, ^smaller, ticket}
    send(smaller, {:release, ticket})
    assert_receive {:released, :smaller}
    assert ResourceGovernor.snapshot(server).queued_background == 1

    assert :ok = Task.Supervisor.terminate_child(task_supervisor, oversized)
    _ = :sys.get_state(server)
    assert ResourceGovernor.snapshot(server).queued_background == 0
  end

  test "an admitted DAG can acquire its nested provider effect under pressure" do
    current = start_supervised!({Agent, fn -> 650 end})

    server =
      start_governor(
        fn ->
          %{
            memory_current_bytes: Agent.get(current, & &1) * @mib,
            memory_limit_bytes: 1_000 * @mib,
            pressure: %{},
            events: %{}
          }
        end,
        headroom_bytes: 0
      )

    assert {:ok, dag} =
             ResourceGovernor.request(:dag_step,
               server: server,
               priority: :background,
               run_key: :run_a
             )

    Agent.update(current, fn _ -> 710 end)

    assert {:ok, provider} =
             ResourceGovernor.request(:llm_provider,
               server: server,
               priority: :background,
               run_key: :run_a,
               timeout: 0
             )

    assert :ok = ResourceGovernor.release(provider, server)
    assert :ok = ResourceGovernor.release(dag, server)
  end

  test "owner DOWN automatically releases capacity", %{task_supervisor: task_supervisor} do
    server = start_governor(memory(0, 1_000), headroom_bytes: 0)
    owner = start_waiter(task_supervisor, server, :owner, :background, :owner)
    assert_receive {:granted, :owner, ^owner, _ticket}

    queued = start_waiter(task_supervisor, server, :queued, :background, :queued)
    await_queue(server, 0, 1)

    assert :ok = Task.Supervisor.terminate_child(task_supervisor, owner)
    assert_receive {:granted, :queued, ^queued, ticket}
    send(queued, {:release, ticket})
    assert_receive {:released, :queued}
  end

  test "governor restart recovers active reservations before admitting new work", %{
    task_supervisor: task_supervisor
  } do
    permit_supervisor =
      start_supervised!(
        {ResourcePermitSupervisor, name: nil},
        id: {:permit_supervisor, make_ref()}
      )

    recovery_key = make_ref()

    governor_supervisor =
      start_supervised!(
        %{
          id: {:restartable_governor_supervisor, make_ref()},
          start:
            {Supervisor, :start_link,
             [
               [
                 Supervisor.child_spec(
                   {ResourceGovernor,
                    name: nil,
                    permit_supervisor: permit_supervisor,
                    recovery_key: recovery_key,
                    read_memory: memory(0, 1_000),
                    poll_interval_ms: :infinity,
                    headroom_bytes: 0},
                   id: :restartable_governor
                 )
               ],
               [strategy: :one_for_one]
             ]},
          type: :supervisor
        },
        id: {:governor_supervisor, make_ref()}
      )

    governor = supervisor_child!(governor_supervisor)
    owner = start_waiter(task_supervisor, governor, :active_owner, :background, :active_run)
    assert_receive {:granted, :active_owner, ^owner, ticket}
    assert ResourceGovernor.snapshot(governor).reserved_bytes == 512 * @mib

    governor_monitor = Process.monitor(governor)
    Process.exit(governor, :kill)
    assert_receive {:DOWN, ^governor_monitor, :process, ^governor, :killed}

    restarted = await_restarted_child(governor_supervisor, governor)

    assert %{
             reserved_bytes: reserved,
             active_by_class: %{build_test: 1}
           } = ResourceGovernor.snapshot(restarted)

    assert reserved == 512 * @mib

    assert {:error, :capacity_timeout} =
             ResourceGovernor.request(:build_test,
               server: restarted,
               priority: :background,
               run_key: :second_run,
               timeout: 0
             )

    send(owner, {:release, ticket})
    assert_receive {:released, :active_owner}
    await_reserved_bytes(restarted, 0)
  end

  test "permit supervisor failure fails closed by terminating admitted owners", %{
    task_supervisor: task_supervisor
  } do
    permit_supervisor =
      start_supervised!(
        {ResourcePermitSupervisor, name: nil},
        id: {:permit_supervisor, make_ref()}
      )

    governor =
      start_governor(memory(0, 1_000),
        headroom_bytes: 0,
        permit_supervisor: permit_supervisor
      )

    owner = start_waiter(task_supervisor, governor, :lease_owner, :background, :lease_run)
    assert_receive {:granted, :lease_owner, ^owner, _ticket}
    owner_monitor = Process.monitor(owner)
    Process.exit(permit_supervisor, :kill)

    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, reason}
    assert reason != :normal
    await_reserved_bytes(governor, 0)
  end

  test "request converts arbitrary server exits and cleans an ungranted lease" do
    permit_supervisor =
      start_supervised!(
        {ResourcePermitSupervisor, name: nil},
        id: {:permit_supervisor, make_ref()}
      )

    test_pid = self()

    fake_server =
      spawn(fn ->
        receive do
          {:"$gen_call", {caller, tag}, :permit_supervisor} ->
            send(caller, {tag, {:ok, permit_supervisor}})
        end

        receive do
          {:"$gen_call", _from,
           {:request, permit_pid, _ticket, _class, _priority, _run, _timeout}} ->
            send(test_pid, {:ungranted_permit, permit_pid})
            exit({:unexpected_admission_failure, :boom})
        end
      end)

    assert {:error, :unavailable} =
             ResourceGovernor.request(:build_test, server: fake_server, timeout: 0)

    assert_receive {:ungranted_permit, permit_pid}
    permit_monitor = Process.monitor(permit_pid)
    assert_receive {:DOWN, ^permit_monitor, :process, ^permit_pid, _reason}
  end

  test "reads cgroup current, max, pressure and events" do
    root = Path.join(System.tmp_dir!(), "resource-governor-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    File.write!(Path.join(root, "memory.current"), "1234\n")
    File.write!(Path.join(root, "memory.max"), "5678\n")
    File.write!(Path.join(root, "memory.pressure"), "some avg10=0.10 total=42\n")
    File.write!(Path.join(root, "memory.events"), "oom 2\noom_kill 1\n")

    assert %{
             memory_current_bytes: 1234,
             memory_limit_bytes: 5678,
             pressure: %{"some" => %{"avg10" => 0.1, "total" => 42}},
             events: %{"oom" => 2, "oom_kill" => 1}
           } = ResourceGovernor.read_cgroup_memory(root)
  end

  defp start_governor(read_memory, opts \\ []) do
    start_supervised!(
      {ResourceGovernor,
       [
         name: nil,
         read_memory: read_memory,
         poll_interval_ms: :infinity
       ] ++ opts},
      id: make_ref()
    )
  end

  defp start_waiter(task_supervisor, server, label, priority, run_key, class \\ :build_test) do
    parent = self()

    {:ok, pid} =
      Task.Supervisor.start_child(task_supervisor, fn ->
        {:ok, ticket} =
          ResourceGovernor.request(class,
            server: server,
            priority: priority,
            run_key: run_key
          )

        send(parent, {:granted, label, self(), ticket})

        receive do
          {:release, ^ticket} ->
            :ok = ResourceGovernor.release(ticket, server)
            send(parent, {:released, label})
        end
      end)

    pid
  end

  defp await_queue(server, interactive, background, attempts \\ 1_000)

  defp await_queue(_server, _interactive, _background, 0),
    do: flunk("governor queue did not reach expected size")

  defp await_queue(server, interactive, background, attempts) do
    snapshot = ResourceGovernor.snapshot(server)

    if snapshot.queued_interactive == interactive and
         snapshot.queued_background == background do
      :ok
    else
      receive do
      after
        0 -> await_queue(server, interactive, background, attempts - 1)
      end
    end
  end

  defp await_pending_count(server, expected, attempts \\ 1_000)

  defp await_pending_count(_server, _expected, 0),
    do: flunk("governor pending set did not reach expected size")

  defp await_pending_count(server, expected, attempts) do
    if server |> :sys.get_state() |> Map.fetch!(:pending) |> map_size() == expected do
      :ok
    else
      receive do
      after
        0 -> await_pending_count(server, expected, attempts - 1)
      end
    end
  end

  defp supervisor_child!(supervisor) do
    case Supervisor.which_children(supervisor) do
      [{:restartable_governor, pid, :worker, _modules}] when is_pid(pid) -> pid
      children -> flunk("expected one running governor child, got: #{inspect(children)}")
    end
  end

  defp await_restarted_child(supervisor, previous, attempts \\ 1_000)

  defp await_restarted_child(_supervisor, _previous, 0),
    do: flunk("governor did not restart")

  defp await_restarted_child(supervisor, previous, attempts) do
    case Supervisor.which_children(supervisor) do
      [{:restartable_governor, pid, :worker, _modules}]
      when is_pid(pid) and pid != previous ->
        pid

      _children ->
        receive do
        after
          0 -> await_restarted_child(supervisor, previous, attempts - 1)
        end
    end
  end

  defp await_reserved_bytes(server, expected, attempts \\ 1_000)

  defp await_reserved_bytes(_server, _expected, 0),
    do: flunk("governor reservation did not reach expected size")

  defp await_reserved_bytes(server, expected, attempts) do
    if ResourceGovernor.snapshot(server).reserved_bytes == expected do
      :ok
    else
      receive do
      after
        0 -> await_reserved_bytes(server, expected, attempts - 1)
      end
    end
  end

  defp memory(current_mib, limit_mib) do
    fn ->
      %{
        memory_current_bytes: current_mib * @mib,
        memory_limit_bytes: limit_mib * @mib,
        pressure: %{},
        events: %{}
      }
    end
  end
end
