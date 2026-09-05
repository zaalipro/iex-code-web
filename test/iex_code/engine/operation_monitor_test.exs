defmodule IexCode.Engine.OperationMonitorTest do
  use IexCode.DataCase, async: false

  alias IexCode.{Projects, Repo, Sessions}
  alias IexCode.Engine.{OperationManager, OperationMonitor, OperationProjection}
  alias IexCode.Sessions.Operation

  import Ecto.Query
  import ExUnit.CaptureLog

  setup do
    {:ok, project} =
      Projects.create_project(%{name: "Operation Monitor Test", root_path: File.cwd!()})

    {:ok, session} =
      Sessions.create_session(%{project_id: project.id, title: "Operation Monitor Test"})

    Phoenix.PubSub.subscribe(IexCode.PubSub, "session:#{session.id}")
    %{session: session}
  end

  test "N concurrent operations use one monitor and no watcher task per operation", %{
    session: session
  } do
    baseline_children = task_children()

    operations =
      for index <- 1..30 do
        {:ok, task_pid, operation} =
          OperationManager.run_async_operation(
            session.id,
            nil,
            "Worker#{index}",
            "bounded_monitor",
            "Operation #{index}",
            %{},
            fn _progress ->
              receive do
                :complete -> {:ok, index}
              end
            end
          )

        {task_pid, operation.id}
      end

    assert %{active: 30, pending_finalizations: 0} = OperationMonitor.snapshot()
    assert task_children() - baseline_children == 30

    Enum.each(operations, fn {task_pid, _operation_id} -> send(task_pid, :complete) end)

    Enum.each(operations, fn {_task_pid, operation_id} ->
      assert_receive {:operation_completed, %Operation{id: ^operation_id}}, 5_000
    end)

    _ = :sys.get_state(OperationMonitor)
    assert %{active: 0, pending_finalizations: 0} = OperationMonitor.snapshot()

    operation_ids = Enum.map(operations, &elem(&1, 1))

    assert Repo.aggregate(
             from(operation in Operation,
               where: operation.id in ^operation_ids and operation.status == "running"
             ),
             :count
           ) == 0
  end

  test "abnormal exits are finalized without dangling running rows", %{session: session} do
    operations =
      for index <- 1..20 do
        {:ok, task_pid, operation} =
          OperationManager.run_async_operation(
            session.id,
            nil,
            "CrashWorker#{index}",
            "crash",
            "Crash #{index}",
            %{},
            fn _progress ->
              receive do
                :crash -> Process.exit(self(), :kill)
              end
            end
          )

        {task_pid, operation.id}
      end

    Enum.each(operations, fn {task_pid, _operation_id} -> send(task_pid, :crash) end)

    Enum.each(operations, fn {_task_pid, operation_id} ->
      assert_receive {:operation_failed, %Operation{id: ^operation_id, status: "failed"}}, 5_000
    end)

    assert :ok = OperationMonitor.await_idle()

    operation_ids = Enum.map(operations, &elem(&1, 1))
    persisted = Repo.all(from operation in Operation, where: operation.id in ^operation_ids)

    assert length(persisted) == 20
    assert Enum.all?(persisted, &(&1.status == "failed"))
    assert %{active: 0, pending_finalizations: 0} = OperationMonitor.snapshot()
  end

  test "idle barrier waits for crash finalization before returning", %{session: session} do
    {:ok, task_pid, operation} =
      OperationManager.run_async_operation(
        session.id,
        nil,
        "BarrierWorker",
        "barrier_crash",
        "Barrier crash",
        %{},
        fn _progress ->
          receive do
            :crash -> Process.exit(self(), :kill)
          end
        end
      )

    send(task_pid, :crash)

    assert :ok = OperationMonitor.await_idle()
    assert %Operation{status: "failed"} = Sessions.get_operation(operation.id)
  end

  test "a registered task that exits normally before terminal persistence is finalized", %{
    session: session
  } do
    {:ok, operation} =
      Sessions.create_operation(%{
        session_id: session.id,
        agent_name: "EarlyNormalExitWorker",
        op_type: "early_normal_exit",
        title: "Exit before terminal persistence",
        status: "running",
        started_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    test_pid = self()

    task_pid =
      start_supervised!(
        Supervisor.child_spec(
          {Task,
           fn ->
             send(test_pid, {:normal_exit_task_ready, self()})
             receive do: (:finish -> :ok)
           end},
          id: :early_normal_exit_operation_task,
          restart: :temporary
        )
      )

    assert_receive {:normal_exit_task_ready, ^task_pid}

    assert :ok =
             OperationMonitor.register(task_pid, %{
               session_id: session.id,
               operation_id: operation.id,
               started_monotonic_ms: System.monotonic_time(:millisecond),
               parent_caller: self(),
               agent_name: operation.agent_name,
               op_type: operation.op_type,
               parent_op_id: operation.parent_op_id
             })

    send(task_pid, :finish)

    assert :ok = OperationMonitor.await_idle()

    assert %Operation{status: "failed", error_message: message} =
             Sessions.get_operation(operation.id)

    assert message =~ "exited normally"
  end

  test "registration stays responsive while crash persistence is blocked" do
    test_pid = self()

    finalizer = fn metadata, _reason ->
      send(test_pid, {:finalization_started, metadata.operation_id})

      receive do
        :release_finalization -> :ok
      end
    end

    monitor =
      start_supervised!(
        {OperationMonitor,
         name: :operation_monitor_responsiveness_test,
         reconcile_on_start: false,
         finalizer: finalizer}
      )

    first =
      spawn(fn ->
        receive do
          :finish -> :ok
        end
      end)

    metadata = %{
      session_id: Ecto.UUID.generate(),
      operation_id: Ecto.UUID.generate(),
      started_monotonic_ms: System.monotonic_time(:millisecond),
      parent_caller: self()
    }

    assert :ok = OperationMonitor.register(first, metadata, monitor)
    Process.exit(first, :kill)
    assert_receive {:finalization_started, _operation_id}, 1_000

    second =
      spawn(fn ->
        receive do
          :finish -> :ok
        end
      end)

    started = System.monotonic_time(:millisecond)

    assert :ok =
             OperationMonitor.register(
               second,
               %{metadata | operation_id: Ecto.UUID.generate()},
               monitor
             )

    assert System.monotonic_time(:millisecond) - started < 50

    state = :sys.get_state(monitor)
    send(state.finalizer_pid, :release_finalization)
    assert :ok = OperationMonitor.unregister(second, monitor)
    send(second, :finish)
    assert :ok = OperationMonitor.await_idle(1_000, monitor)
  end

  test "finalizer failure terminates the monitor and linked operations fail closed" do
    {:ok, monitor} =
      OperationMonitor.start_link(
        name: :operation_monitor_finalizer_failure_test,
        reconcile_on_start: false,
        finalizer: fn _metadata, _reason -> :ok end
      )

    Process.unlink(monitor)

    waiting_task =
      spawn(fn ->
        receive do
          :finish -> :ok
        end
      end)

    base_metadata = %{
      session_id: Ecto.UUID.generate(),
      operation_id: Ecto.UUID.generate(),
      started_monotonic_ms: System.monotonic_time(:millisecond),
      parent_caller: self()
    }

    assert :ok = OperationMonitor.register(waiting_task, base_metadata, monitor)

    capture_log(fn ->
      monitor_ref = Process.monitor(monitor)
      waiting_ref = Process.monitor(waiting_task)
      state = :sys.get_state(monitor)
      Process.exit(state.finalizer_pid, :kill)

      assert_receive {:DOWN, ^monitor_ref, :process, ^monitor,
                      {:operation_finalizer_exited, :killed}},
                     1_000

      assert_receive {:DOWN, ^waiting_ref, :process, ^waiting_task,
                      {:operation_finalizer_exited, :killed}},
                     1_000
    end)
  end

  test "registration stays responsive while startup reconciliation is blocked" do
    test_pid = self()

    reconciler = fn ->
      send(test_pid, :reconciliation_started)

      receive do
        :release_reconciliation -> :ok
      end
    end

    monitor =
      start_supervised!(
        {OperationMonitor,
         name: :operation_monitor_reconciliation_responsiveness_test,
         reconcile_on_start: true,
         reconciliation_delay_ms: 0,
         reconciliation_grace_seconds: 0,
         reconciler: reconciler}
      )

    assert_receive :reconciliation_started, 1_000

    waiting_task =
      spawn(fn ->
        receive do
          :finish -> :ok
        end
      end)

    metadata = %{
      session_id: Ecto.UUID.generate(),
      operation_id: Ecto.UUID.generate(),
      started_monotonic_ms: System.monotonic_time(:millisecond),
      parent_caller: self()
    }

    started = System.monotonic_time(:millisecond)
    assert :ok = OperationMonitor.register(waiting_task, metadata, monitor)
    assert System.monotonic_time(:millisecond) - started < 50

    state = :sys.get_state(monitor)
    send(state.finalizer_pid, :release_reconciliation)
    assert :ok = OperationMonitor.unregister(waiting_task, monitor)
    send(waiting_task, :finish)
    assert :ok = OperationMonitor.await_idle(1_000, monitor)
  end

  test "monitor restart fails closed and reconciles its durable running operation", %{
    session: session
  } do
    Application.put_env(:iex_code, :operation_monitor_reconcile_on_start, true)

    on_exit(fn ->
      Application.put_env(:iex_code, :operation_monitor_reconcile_on_start, false)
    end)

    {:ok, task_pid, operation} =
      OperationManager.run_async_operation(
        session.id,
        nil,
        "RestartWorker",
        "monitor_restart",
        "Restart monitor",
        %{},
        fn _progress ->
          receive do
            :never -> {:ok, :unexpected}
          end
        end
      )

    old_monitor = Process.whereis(OperationMonitor)
    task_ref = Process.monitor(task_pid)
    monitor_ref = Process.monitor(old_monitor)
    Process.exit(old_monitor, :kill)

    assert_receive {:DOWN, ^monitor_ref, :process, ^old_monitor, :killed}, 5_000
    assert_receive {:DOWN, ^task_ref, :process, ^task_pid, _reason}, 5_000

    new_monitor = await_restarted_monitor(old_monitor, 5_000)
    assert is_pid(new_monitor)
    _ = :sys.get_state(new_monitor)

    assert_receive {:operation_failed,
                    %Operation{id: operation_id, status: "failed", error_message: message}},
                   5_000

    assert operation_id == operation.id
    assert message =~ "monitor restarted"
    assert Sessions.get_operation(operation.id).status == "failed"
  end

  test "startup reconciliation keysets through multiple bounded pages", %{session: session} do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    inserted_at = DateTime.add(now, -10, :second)

    rows =
      Enum.map(1..205, fn index ->
        %{
          id: Ecto.UUID.generate(),
          session_id: session.id,
          parent_op_id: nil,
          agent_name: "Orphan#{index}",
          op_type: "startup_reconciliation",
          title: "Orphan #{index}",
          status: "running",
          progress: 0,
          result: String.duplicate("r", 32 * 1_024),
          started_at: now,
          inserted_at: inserted_at,
          updated_at: inserted_at
        }
      end)

    {_count, nil} = Repo.insert_all(Operation, rows)
    expected_ids = rows |> Enum.map(& &1.id) |> MapSet.new()

    _monitor =
      start_supervised!(
        {OperationMonitor,
         name: :operation_monitor_batched_reconciliation_test,
         reconcile_on_start: true,
         reconciliation_delay_ms: 0,
         reconciliation_grace_seconds: 0}
      )

    assert_reconciled_ids(expected_ids, 15_000)

    assert Repo.aggregate(
             from(operation in Operation,
               where:
                 operation.id in ^MapSet.to_list(expected_ids) and operation.status == "running"
             ),
             :count
           ) == 0
  end

  test "startup reconciliation fences an operation registered after page selection", %{
    session: session
  } do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    operation_id = Ecto.UUID.generate()

    {_count, nil} =
      Repo.insert_all(Operation, [
        %{
          id: operation_id,
          session_id: session.id,
          parent_op_id: nil,
          agent_name: "RegistrationRace",
          op_type: "startup_reconciliation",
          title: "Register during page selection",
          status: "running",
          progress: 0,
          started_at: now,
          inserted_at: DateTime.add(now, -10, :second),
          updated_at: DateTime.add(now, -10, :second)
        }
      ])

    test_pid = self()

    page_hook = fn page ->
      if Enum.any?(page, &(&1.id == operation_id)) do
        send(test_pid, :reconciliation_page_selected)

        receive do
          :continue_reconciliation -> :ok
        end
      end
    end

    monitor =
      start_supervised!(
        {OperationMonitor,
         name: :operation_monitor_registration_fence_test,
         reconcile_on_start: true,
         reconciliation_delay_ms: 0,
         reconciliation_grace_seconds: 0,
         reconciliation_page_hook: page_hook}
      )

    assert_receive :reconciliation_page_selected, 2_000

    task_pid =
      spawn(fn ->
        receive do
          :finish -> :ok
        end
      end)

    assert :ok =
             OperationMonitor.register(
               task_pid,
               %{
                 session_id: session.id,
                 operation_id: operation_id,
                 started_monotonic_ms: System.monotonic_time(:millisecond),
                 parent_caller: self()
               },
               monitor
             )

    state = :sys.get_state(monitor)
    send(state.finalizer_pid, :continue_reconciliation)

    assert_reconciliation_finished(monitor, 2_000)
    assert %Operation{status: "running"} = Sessions.get_operation(operation_id)
    refute_receive {:operation_failed, %Operation{id: ^operation_id}}, 50

    send(task_pid, :finish)
    assert :ok = OperationMonitor.await_idle(1_000, monitor)
  end

  test "durable finalization failure propagates and central retries eventually persist", %{
    session: session
  } do
    assert :error =
             OperationManager.finalize_abnormal_exit(
               %{
                 session_id: session.id,
                 operation_id: Ecto.UUID.generate(),
                 started_monotonic_ms: System.monotonic_time(:millisecond),
                 parent_caller: self()
               },
               :simulated_missing_row
             )

    {:ok, operation} =
      Sessions.create_operation(%{
        session_id: session.id,
        agent_name: "RetryWorker",
        op_type: "retry_finalization",
        title: "Retry durable finalization",
        status: "running",
        started_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    failures = start_supervised!({Agent, fn -> 3 end})

    finalizer = fn metadata, reason ->
      Agent.get_and_update(failures, fn
        remaining when remaining > 0 -> {:error, remaining - 1}
        0 -> {OperationManager.finalize_abnormal_exit(metadata, reason), 0}
      end)
    end

    monitor =
      start_supervised!(
        {OperationMonitor,
         name: :operation_monitor_durable_retry_test,
         reconcile_on_start: false,
         finalizer: finalizer}
      )

    task_pid =
      spawn(fn ->
        receive do
          :crash -> Process.exit(self(), :kill)
        end
      end)

    assert :ok =
             OperationMonitor.register(
               task_pid,
               %{
                 session_id: session.id,
                 operation_id: operation.id,
                 started_monotonic_ms: System.monotonic_time(:millisecond),
                 parent_caller: self(),
                 agent_name: operation.agent_name,
                 op_type: operation.op_type,
                 parent_op_id: nil
               },
               monitor
             )

    send(task_pid, :crash)
    assert :ok = OperationMonitor.await_idle(5_000, monitor)
    assert Agent.get(failures, & &1) == 0
    assert %Operation{status: "failed"} = Sessions.get_operation(operation.id)
  end

  test "large direct results remain intact while durable and broadcast projections are bounded",
       %{
         session: session
       } do
    full_result = String.duplicate("0123456789", 20_000)

    assert {:ok, ^full_result} =
             OperationManager.run_sync_operation(
               session.id,
               nil,
               "LargeResultWorker",
               "large_result",
               "Large result",
               %{"nested" => String.duplicate("p", 100_000)},
               fn progress ->
                 progress.(50, String.duplicate("m", 100_000))
                 {:ok, full_result}
               end
             )

    assert_receive {:operation_progress, _operation_id, 50, projected_progress}, 5_000
    assert byte_size(projected_progress) <= OperationProjection.max_text_bytes()

    assert_receive {:operation_completed, %Operation{} = completed}, 5_000
    assert byte_size(completed.result) <= OperationProjection.max_text_bytes()
    assert completed.result =~ "bytes omitted"

    persisted = Sessions.get_operation(completed.id)
    assert byte_size(persisted.result) <= OperationProjection.max_text_bytes()
    assert byte_size(Jason.encode!(persisted.params)) <= OperationProjection.max_params_bytes()
  end

  test "artifact references survive bounded structured result projection" do
    artifact_id = Ecto.UUID.generate()

    projected =
      OperationProjection.text(%{
        artifact_id: artifact_id,
        output: String.duplicate("x", 100_000)
      })

    assert byte_size(projected) <= OperationProjection.max_text_bytes()
    assert projected =~ artifact_id
  end

  test "operation changeset rejects oversized unprojected text and params", %{session: session} do
    base = %{
      session_id: session.id,
      agent_name: "SchemaWorker",
      op_type: "schema",
      title: "Schema bounds"
    }

    text_changeset =
      Operation.changeset(
        %Operation{},
        Map.put(base, :result, String.duplicate("x", OperationProjection.max_text_bytes() + 1))
      )

    refute text_changeset.valid?
    assert {"must be at most 65536 bytes", _} = text_changeset.errors[:result]

    params_changeset =
      Operation.changeset(
        %Operation{},
        Map.put(base, :params, %{"value" => String.duplicate("x", 70_000)})
      )

    refute params_changeset.valid?
    assert {"must be a JSON value of at most 64000 bytes", _} = params_changeset.errors[:params]
  end

  test "finalizer exits are contained and never terminate the central monitor" do
    monitor = Process.whereis(OperationMonitor)

    assert :error =
             OperationMonitor.safe_finalize(fn ->
               exit({:db_checkout_failed, :sandbox_owner_down})
             end)

    assert Process.alive?(monitor)
    assert %{active: 0, pending_finalizations: 0} = OperationMonitor.snapshot()
  end

  test "an operation task self-terminates when monitor registration is never acknowledged" do
    task_pid =
      Task.Supervisor.start_child(IexCode.TaskSupervisor, fn ->
        OperationManager.await_monitor_registration("unregistered-operation", 10)
      end)
      |> elem(1)

    ref = Process.monitor(task_pid)

    assert_receive {:DOWN, ^ref, :process, ^task_pid, :operation_monitor_registration_timeout},
                   1_000

    refute task_pid in Task.Supervisor.children(IexCode.TaskSupervisor)
  end

  defp task_children, do: IexCode.TaskSupervisor |> Task.Supervisor.children() |> length()

  defp assert_reconciled_ids(expected_ids, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_assert_reconciled_ids(expected_ids, deadline)
  end

  defp assert_reconciliation_finished(monitor, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_assert_reconciliation_finished(monitor, deadline)
  end

  defp do_assert_reconciliation_finished(monitor, deadline) do
    case OperationMonitor.snapshot(monitor) do
      %{reconciliation_in_progress?: false} ->
        :ok

      _snapshot ->
        remaining = deadline - System.monotonic_time(:millisecond)

        receive do
        after
          min(max(remaining, 0), 10) ->
            if remaining <= 0,
              do: flunk("startup reconciliation did not finish"),
              else: do_assert_reconciliation_finished(monitor, deadline)
        end
    end
  end

  defp do_assert_reconciled_ids(expected_ids, deadline) do
    if MapSet.size(expected_ids) == 0 do
      :ok
    else
      remaining = max(deadline - System.monotonic_time(:millisecond), 0)

      receive do
        {:operation_failed, %Operation{id: id, status: "failed"}} ->
          do_assert_reconciled_ids(MapSet.delete(expected_ids, id), deadline)
      after
        remaining ->
          flunk(
            "startup reconciliation left #{MapSet.size(expected_ids)} operation(s) unfinished"
          )
      end
    end
  end

  defp await_restarted_monitor(old_monitor, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await_restarted_monitor(old_monitor, deadline)
  end

  defp do_await_restarted_monitor(old_monitor, deadline) do
    case Process.whereis(OperationMonitor) do
      pid when is_pid(pid) and pid != old_monitor ->
        pid

      _other ->
        remaining = deadline - System.monotonic_time(:millisecond)

        receive do
        after
          min(max(remaining, 0), 10) ->
            if remaining <= 0,
              do: flunk("OperationMonitor did not restart"),
              else: do_await_restarted_monitor(old_monitor, deadline)
        end
    end
  end
end
