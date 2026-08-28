defmodule IexCodeWeb.WorkspaceLiveInstrumentSummariesTest do
  use IexCode.E2E.Case, async: false

  alias IexCode.{Kanban, Repo, Runs}
  alias IexCode.Tools.Git.StatusResult

  def snapshot do
    test_pid = Application.fetch_env!(:iex_code, :workspace_summary_test_pid)
    send(test_pid, {:runtime_snapshot_requested, self()})

    receive do
      {:runtime_snapshot_reply, :raise} -> raise "Runtime snapshot exploded"
      {:runtime_snapshot_reply, result} -> result
    end
  end

  def status(root, opts) do
    test_pid = Application.fetch_env!(:iex_code, :workspace_summary_test_pid)
    send(test_pid, {:git_status_requested, self(), root, opts})

    receive do
      {:git_status_reply, :raise} -> raise "Git status exploded"
      {:git_status_reply, result} -> result
    end
  end

  def current_branch(_root), do: {:ok, "summary-test"}

  def summary(project_id) do
    case Application.get_env(:iex_code, :workspace_kanban_summary_mode, :ok) do
      :raise -> raise "Kanban summary exploded"
      :ok -> Kanban.summary(project_id)
    end
  end

  setup do
    previous_runtime = Application.get_env(:iex_code, :runtime_status_reader)
    previous_git = Application.get_env(:iex_code, :git_summary_reader)
    previous_pid = Application.get_env(:iex_code, :workspace_summary_test_pid)
    previous_kanban = Application.get_env(:iex_code, :kanban_summary_reader)
    previous_kanban_mode = Application.get_env(:iex_code, :workspace_kanban_summary_mode)

    Application.put_env(:iex_code, :runtime_status_reader, __MODULE__)
    Application.put_env(:iex_code, :git_summary_reader, __MODULE__)
    Application.put_env(:iex_code, :workspace_summary_test_pid, self())
    Application.put_env(:iex_code, :kanban_summary_reader, __MODULE__)
    Application.put_env(:iex_code, :workspace_kanban_summary_mode, :ok)

    on_exit(fn ->
      restore_env(:runtime_status_reader, previous_runtime)
      restore_env(:git_summary_reader, previous_git)
      restore_env(:workspace_summary_test_pid, previous_pid)
      restore_env(:kanban_summary_reader, previous_kanban)
      restore_env(:workspace_kanban_summary_mode, previous_kanban_mode)
    end)

    :ok
  end

  test "Kanban query failure yields exact unavailable summaries instead of filtered task data", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)

    {:ok, _task} =
      Kanban.create_task(%{project_id: project.id, title: "Must not leak", status: "running"})

    Application.put_env(:iex_code, :workspace_kanban_summary_mode, :raise)

    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
    complete_background_reads()
    summaries = assigns(view).instrument_summaries

    assert summaries["kanban"].primary == "Board unavailable"
    assert summaries["calendar"].primary == "Schedule unavailable"
  end

  test "mount initializes truthful closed summaries and canonical session destinations", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    assert_receive {:runtime_snapshot_requested, runtime_task}
    assert_receive {:git_status_requested, git_task, ^path, git_opts}
    assert git_opts[:path_limit] == 500
    assert git_opts[:output_limit_bytes] == 1_048_576

    assigns = assigns(view)

    assert Map.keys(assigns.instrument_summaries) |> Enum.sort() ==
             ~w(calendar changes chat files kanban research swarm terminal)

    assert assigns.runtime_refresh_pending?
    assert assigns.deck_git_generation == 1
    assert assigns.deck_git_in_flight == %{project_id: project.id, generation: 1}
    assert assigns.deck_git_queued_project_id == nil
    refute assigns.terminal_available?
    assert assigns.instrument_summaries["swarm"].primary == "No active run"
    assert assigns.instrument_summaries["kanban"].primary == "No tasks yet"
    assert assigns.instrument_summaries["research"].primary == "No research runs"
    assert assigns.instrument_summaries["chat"].primary == "No messages yet"
    assert assigns.instrument_summaries["files"].primary == "Standby · files not loaded"
    assert assigns.instrument_summaries["terminal"].primary == "Terminal unavailable"

    assert Enum.all?(assigns.instrument_summaries, fn {_surface, summary} ->
             String.starts_with?(summary.destination, "/sessions/#{session.id}")
           end)

    send(runtime_task, {:runtime_snapshot_reply, %{state: :idle}})
    send(git_task, {:git_status_reply, {:error, :not_a_repository}})
  end

  test "runtime and Git refreshes are single-flight and clear markers on outcomes", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    assert_receive {:runtime_snapshot_requested, runtime_task}
    assert_receive {:git_status_requested, git_task, ^path, _opts}

    send(view.pid, :refresh_runtime_status)
    render_click(view, "refresh_git_summary", %{})
    render_click(view, "refresh_git_summary", %{})
    _ = :sys.get_state(view.pid)
    refute_receive {:runtime_snapshot_requested, _other_task}, 50
    refute_receive {:git_status_requested, _other_task, _root, _opts}, 50

    snapshot = %{state: :active, dispatcher: %{active: 1, queued: 0, capacity: 2}}
    send(runtime_task, {:runtime_snapshot_reply, snapshot})
    runtime_ref = Process.monitor(runtime_task)
    assert_receive {:DOWN, ^runtime_ref, :process, ^runtime_task, :normal}

    status = %StatusResult{branch: "main", untracked: ["one.ex"], clean?: false}
    send(git_task, {:git_status_reply, {:ok, status}})
    git_ref = Process.monitor(git_task)
    assert_receive {:DOWN, ^git_ref, :process, ^git_task, :normal}

    assert_receive {:git_status_requested, queued_task, ^path, _opts}
    send(queued_task, {:git_status_reply, {:error, :offline}})
    queued_ref = Process.monitor(queued_task)
    assert_receive {:DOWN, ^queued_ref, :process, ^queued_task, :normal}

    assigns = assigns(view)
    refute assigns.runtime_refresh_pending?
    assert assigns.runtime_status == snapshot
    assert assigns.deck_git_generation == 3
    assert assigns.deck_git_in_flight == nil
    assert assigns.deck_git_queued_project_id == nil
    assert %{assigns.git_status | branch: status.branch} == status
    assert assigns.git_status.branch == "summary-test"
    assert assigns.instrument_summaries["changes"].primary == "Git unavailable"
  end

  test "runtime task exit clears the single-flight marker and falls back to unavailable", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    assert_receive {:runtime_snapshot_requested, runtime_task}
    assert_receive {:git_status_requested, git_task, ^path, _opts}
    runtime_ref = Process.monitor(runtime_task)
    send(runtime_task, {:runtime_snapshot_reply, :raise})
    assert_receive {:DOWN, ^runtime_ref, :process, ^runtime_task, _reason}
    send(git_task, {:git_status_reply, {:error, :not_a_repository}})

    status = assigns(view)
    refute status.runtime_refresh_pending?
    assert status.runtime_status == %{state: :unavailable}
  end

  test "an owning Git task exit retires its slot and advances the queued refresh", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    assert_receive {:runtime_snapshot_requested, runtime_task}
    assert_receive {:git_status_requested, git_task, ^path, _opts}

    render_click(view, "refresh_git_summary", %{})
    assert assigns(view).deck_git_queued_project_id == project.id

    send(git_task, {:git_status_reply, :raise})
    git_ref = Process.monitor(git_task)
    assert_receive {:DOWN, ^git_ref, :process, ^git_task, _reason}
    assert_receive {:git_status_requested, queued_task, ^path, _opts}

    marker = assigns(view).deck_git_in_flight
    assert marker == %{project_id: project.id, generation: 2}

    send(queued_task, {:git_status_reply, {:error, :offline}})
    send(runtime_task, {:runtime_snapshot_reply, %{state: :idle}})
  end

  test "project-switch handoff discards the old Git result and fences a late stale generation", %{
    conn: conn,
    workspace_path: path
  } do
    project_a = create_project_fixture(%{root_path: path})
    session_a = create_session_fixture(project_a)
    path_b = create_temp_workspace(%{})
    project_b = create_project_fixture(%{root_path: path_b})
    session_b = create_session_fixture(project_b)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session_a.id}")

    assert_receive {:runtime_snapshot_requested, runtime_task}
    assert_receive {:git_status_requested, task_a, ^path, _opts}
    render_patch(view, ~p"/sessions/#{session_b.id}")
    refute_receive {:git_status_requested, _task_b, ^path_b, _opts}, 50

    stale_status = %StatusResult{branch: "stale-a", untracked: ["old.ex"], clean?: false}
    ref_a = Process.monitor(task_a)
    send(task_a, {:git_status_reply, {:ok, stale_status}})
    assert_receive {:DOWN, ^ref_a, :process, ^task_a, _reason}
    assert_receive {:git_status_requested, task_b, ^path_b, _opts}

    handoff = assigns(view)
    assert handoff.project.id == project_b.id
    refute handoff.git_status == stale_status
    assert handoff.deck_git_in_flight == %{project_id: project_b.id, generation: 2}

    fresh_status = %StatusResult{
      branch: "fresh-b",
      staged: [%{path: "new.ex", status: :added, old_path: nil}],
      clean?: false
    }

    send(task_b, {:git_status_reply, {:ok, fresh_status}})
    send(runtime_task, {:runtime_snapshot_reply, %{state: :idle}})
  end

  test "cross-project rehydrate clears editor and detailed Git state while same-project keeps buffers",
       %{
         conn: conn,
         workspace_path: path_a
       } do
    File.write!(Path.join(path_a, "a.ex"), "old-a")
    project_a = create_project_fixture(%{root_path: path_a})
    session_a1 = create_session_fixture(project_a)
    session_a2 = create_session_fixture(project_a)
    path_b = create_temp_workspace(%{"b.ex" => "safe-b"})
    project_b = create_project_fixture(%{root_path: path_b})
    session_b = create_session_fixture(project_b)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session_a1.id}")
    complete_background_reads()

    render_patch(view, ~p"/sessions/#{session_a1.id}?view=files")
    render_click(view, "select_file", %{"path" => "a.ex"})
    render_change(view, "file_content_changed", %{"content" => "dirty-a"})
    render_patch(view, ~p"/sessions/#{session_a2.id}?view=files")

    same_project = assigns(view)
    assert same_project.selected_file == "a.ex"
    assert same_project.is_dirty?
    assert [%{path: "a.ex"}] = Enum.map(same_project.open_buffers, &Map.take(&1, [:path]))

    render_patch(view, ~p"/sessions/#{session_b.id}?view=files")
    switched = assigns(view)

    assert switched.open_buffers == []
    assert switched.selected_file == nil
    assert switched.file_content == nil
    assert switched.dirty_content == nil
    refute switched.is_dirty?
    assert switched.parsed_diffs == []
    assert switched.staged_diffs == []
    assert switched.unstaged_diffs == []
    assert switched.diff_text == ""
    refute switched.diff_truncated?
    assert switched.diff_mode == "inline"
    assert switched.diff_file_path == nil
    assert switched.diff_hunks == []
    assert switched.git_branches == []
    assert switched.current_branch == "main"
    assert switched.git_status == nil

    render_click(view, "save_file", %{"content" => "must-not-write"})
    assert File.read!(Path.join(path_a, "a.ex")) == "old-a"
    assert File.read!(Path.join(path_b, "b.ex")) == "safe-b"
  end

  test "stale operation callbacks and clear cannot corrupt the current session test summary", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session_a = create_session_fixture(project)
    session_b = create_session_fixture(project)

    stale =
      create_operation_fixture(session_a, %{
        op_type: "run_tests",
        status: "failed",
        duration_ms: 9
      })

    current =
      create_operation_fixture(session_b, %{
        op_type: "run_tests",
        status: "completed",
        duration_ms: 31
      })

    {:ok, view, _html} = live(conn, ~p"/sessions/#{session_a.id}")
    complete_background_reads()
    render_patch(view, ~p"/sessions/#{session_b.id}")

    send(view.pid, {:operation_started, stale})
    send(view.pid, {:operation_created, stale})
    send(view.pid, {:operation_updated, %{stale | status: "completed", duration_ms: 1}})
    send(view.pid, {:operation_progress, stale.id, 99, "stale"})
    send(view.pid, {:operation_completed, stale})
    send(view.pid, {:operation_failed, stale})
    send(view.pid, :operations_cleared)
    _ = :sys.get_state(view.pid)

    state = assigns(view)
    assert Enum.map(state.operations, & &1.id) == [current.id]

    assert %{label: "Latest test operation", value: "completed · 31 ms"} in state.instrument_summaries[
             "changes"
           ].secondary
  end

  test "File Atlas receives bounded Git relation for success truncation and error", %{
    conn: conn,
    workspace_path: path
  } do
    File.write!(Path.join(path, "tracked.ex"), "tracked")
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
    assert_receive {:runtime_snapshot_requested, runtime_task}
    assert_receive {:git_status_requested, git_task, ^path, _opts}
    render_patch(view, ~p"/sessions/#{session.id}?view=files")

    status = %StatusResult{branch: "main", untracked: ["tracked.ex"], clean?: false}
    send(git_task, {:git_status_reply, {:ok, status}})
    _ = :sys.get_state(view.pid)

    assert %{label: "Git", value: "Git · 1 change"} in assigns(view).instrument_summaries["files"].secondary

    render_click(view, "refresh_git_summary", %{})
    assert_receive {:git_status_requested, truncated_task, ^path, _opts}
    send(truncated_task, {:git_status_reply, {:ok, %{status | truncated?: true}}})
    _ = :sys.get_state(view.pid)

    assert %{label: "Git", value: "Git status truncated"} in assigns(view).instrument_summaries[
             "files"
           ].secondary

    render_click(view, "refresh_git_summary", %{})
    assert_receive {:git_status_requested, error_task, ^path, _opts}
    send(error_task, {:git_status_reply, {:error, :offline}})
    send(runtime_task, {:runtime_snapshot_reply, %{state: :idle}})
    _ = :sys.get_state(view.pid)

    assert %{label: "Git", value: "Git unavailable"} in assigns(view).instrument_summaries[
             "files"
           ].secondary
  end

  test "active mission selection is status-prioritized and independent of selected workbench run",
       %{
         conn: conn,
         workspace_path: path
       } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)

    {:ok, running} = create_run(project, session, "Running mission", "running", 37)

    {:ok, _step} =
      Runs.create_step(running, %{
        key: "execute",
        kind: "analysis",
        title: "Execute safely",
        status: "running"
      })

    {:ok, paused} = create_run(project, session, "Newer paused detail run", "paused", 71)

    _running = retime(running, ~U[2026-08-28 10:00:00Z])
    paused = retime(paused, ~U[2026-08-28 11:00:00Z])

    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
    complete_background_reads()

    assigns = assigns(view)
    assert assigns.selected_run.id == paused.id
    assert assigns.instrument_summaries["swarm"].primary == "Running mission"
    assert assigns.instrument_summaries["swarm"].detail == "Execute safely"
    assert %{label: "Progress", value: "37%"} in assigns.instrument_summaries["swarm"].secondary
  end

  test "board aggregate ignores filters and latest durable message is bounded", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)

    {:ok, _task} =
      Kanban.create_task(%{project_id: project.id, title: "Blocked signal", status: "blocked"})

    latest =
      create_message_fixture(session, %{content: String.duplicate("é", 200), agent_name: "User"})

    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
    complete_background_reads()

    before_filter = assigns(view).instrument_summaries["kanban"]
    render_change(view, "filter_kanban", %{"search" => "does-not-match"})
    after_filter = assigns(view).instrument_summaries["kanban"]

    assert before_filter.primary == "1 task"
    assert before_filter.status == :attention
    assert after_filter == before_filter
    assert assigns(view).latest_message_summary.id == latest.id
    assert String.length(assigns(view).instrument_summaries["chat"].primary) == 160
  end

  test "research rounds and newest test operation use bounded durable facts", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)

    {:ok, research} =
      Runs.create_run(%{
        project_id: project.id,
        session_id: session.id,
        objective: "Trace the evidence",
        kind: "deep_research",
        mode: "research",
        status: "completed",
        metadata: %{"research" => %{"level" => "ultra"}}
      })

    for round <- 1..5 do
      {:ok, _step} =
        Runs.create_step(research, %{
          key: "research.evidence.merge.#{round}",
          kind: "aggregate",
          title: "Merge round #{round}",
          status: "completed",
          completed_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })
    end

    old =
      create_operation_fixture(session, %{op_type: "run_tests", status: "failed", duration_ms: 8})

    newest =
      create_operation_fixture(session, %{
        op_type: "run_tests",
        status: "completed",
        duration_ms: 21
      })

    _old = retime(old, ~U[2026-08-28 10:00:00Z])
    newest = retime(newest, ~U[2026-08-28 11:00:00Z])

    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
    complete_background_reads()

    research_summary = assigns(view).instrument_summaries["research"]
    changes_summary = assigns(view).instrument_summaries["changes"]

    assert %{label: "Level", value: "Ultra"} in research_summary.secondary
    assert %{label: "Round", value: "4/4 complete"} in research_summary.secondary
    assert assigns(view).research_summary_steps |> length() == 5

    assert %{label: "Latest test operation", value: "#{newest.status} · 21 ms"} in changes_summary.secondary
  end

  defp create_run(project, session, objective, status, progress) do
    Runs.create_run(%{
      project_id: project.id,
      session_id: session.id,
      objective: objective,
      kind: "analysis",
      mode: "single",
      status: status,
      progress: progress
    })
  end

  defp complete_background_reads do
    assert_receive {:runtime_snapshot_requested, runtime_task}
    assert_receive {:git_status_requested, git_task, _root, _opts}
    send(runtime_task, {:runtime_snapshot_reply, %{state: :idle}})

    send(
      git_task,
      {:git_status_reply, {:ok, %StatusResult{branch: "main", clean?: true}}}
    )
  end

  defp assigns(view) do
    _ = :sys.get_state(view.pid)
    :sys.get_state(view.pid).socket.assigns
  end

  defp restore_env(key, nil), do: Application.delete_env(:iex_code, key)
  defp restore_env(key, value), do: Application.put_env(:iex_code, key, value)

  defp retime(struct, inserted_at) do
    struct
    |> Ecto.Changeset.change(inserted_at: inserted_at, updated_at: inserted_at)
    |> Repo.update!()
  end
end
