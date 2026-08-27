defmodule IexCode.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  You may define functions here to be used as helpers in
  your tests.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use IexCode.DataCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias IexCode.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import IexCode.DataCase
    end
  end

  setup tags do
    IexCode.DataCase.setup_sandbox(tags)
    :ok
  end

  @doc """
  Sets up the sandbox based on the test tags and ensures 100% clean process draining on exit.
  """
  def setup_sandbox(tags) do
    # 0. Drain any lingering processes before test starts
    drain_all_processes()

    pid =
      try do
        Ecto.Adapters.SQL.Sandbox.start_owner!(IexCode.Repo,
          shared: not tags[:async],
          ownership_timeout: 120_000
        )
      rescue
        _ -> nil
      end

    if pid do
      on_exit(fn ->
        try do
          # Synchronous operation callers are deliberately released before a
          # contended terminal persistence write. Give those already-complete
          # operation tasks a short grace period to unregister cleanly before
          # forcibly draining supervisors; killing a task while SQL Sandbox is
          # serving its final write disconnects the shared connection and
          # creates noisy, slow cross-test retries in the central finalizer.
          _ = IexCode.Engine.OperationMonitor.await_idle(250)

          # 1. Synchronously terminate and await all child processes before stopping sandbox owner
          drain_all_processes()

          # OperationMonitor is application-scoped rather than owned by an
          # individual test. Wait for it to consume every task DOWN and finish
          # its durable crash writes while this test's shared sandbox owner is
          # still alive. Otherwise the next test can receive stale PubSub /
          # telemetry and the SQLite connection can be torn away mid-query.
          case IexCode.Engine.OperationMonitor.await_idle() do
            :ok -> :ok
            {:error, :timeout} -> raise "OperationMonitor did not quiesce before sandbox teardown"
          end
        after
          # 2. Stop Sandbox Owner only after application-scoped finalizers are idle.
          Ecto.Adapters.SQL.Sandbox.stop_owner(pid)
        end
      end)
    end

    :ok
  end

  @doc """
  Synchronously terminates and awaits exit for all child processes across
  TaskSupervisor, AgentSupervisor, and SessionSupervisor with multi-pass confirmation.
  """
  def drain_all_processes do
    # Per-run fleet supervisors own their own agent/task supervisors, so drain
    # them before the shared compatibility supervisors and sandbox owner.
    terminate_supervisor_children(IexCode.Engine.FleetSupervisor, :dynamic)

    # Pass 1: Monitored termination of TaskSupervisor children
    terminate_supervisor_children(IexCode.TaskSupervisor, :task)

    # Pass 2: Monitored termination of AgentSupervisor children
    terminate_supervisor_children(IexCode.Engine.AgentSupervisor, :dynamic)

    # Pass 3: Monitored termination of SessionSupervisor children
    terminate_supervisor_children(IexCode.Engine.SessionSupervisor, :dynamic)

    # Pass 4: Monitored termination of TerminalSupervisor children
    terminate_supervisor_children(IexCode.Tools.TerminalSupervisor, :dynamic)

    # Pass 5: Flush Registries
    if Process.whereis(IexCode.Engine.AgentRegistry) do
      try do
        _ = :sys.get_state(IexCode.Engine.AgentRegistry)
      rescue
        _ -> :ok
      catch
        _, _ -> :ok
      end
    end

    if Process.whereis(IexCode.SessionRegistry) do
      try do
        _ = :sys.get_state(IexCode.SessionRegistry)
      rescue
        _ -> :ok
      catch
        _, _ -> :ok
      end
    end

    :ok
  end

  defp terminate_supervisor_children(sup_name, sup_type) do
    if Process.whereis(sup_name) do
      pids =
        case sup_type do
          :task ->
            Task.Supervisor.children(sup_name)

          :dynamic ->
            DynamicSupervisor.which_children(sup_name)
            |> Enum.map(fn {_, child_pid, _, _} -> child_pid end)
        end
        |> Enum.filter(&is_pid/1)
        |> Enum.filter(&Process.alive?/1)

      refs =
        for pid <- pids do
          ref = Process.monitor(pid)

          case sup_type do
            :task -> Task.Supervisor.terminate_child(sup_name, pid)
            :dynamic -> DynamicSupervisor.terminate_child(sup_name, pid)
          end

          {pid, ref}
        end

      for {pid, ref} <- refs do
        receive do
          {:DOWN, ^ref, :process, ^pid, _} -> :ok
        after
          500 ->
            Process.demonitor(ref, [:flush])
            if Process.alive?(pid), do: Process.exit(pid, :kill)
        end
      end
    end
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  @doc """
  A helper that transforms changeset errors into a map of messages.

      assert {:error, changeset} = Accounts.create_user(%{password: "short"})
      assert "password is too short" in errors_on(changeset).password
      assert %{password: ["password is too short"]} = errors_on(changeset)

  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
