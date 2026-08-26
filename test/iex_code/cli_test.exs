defmodule IexCode.CLITest do
  use IexCode.E2E.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias IexCode.Projects.Project
  alias IexCode.Runs.Run
  alias IexCode.Sessions.Session
  alias IexCode.{CLI, Repo, Runs}

  test "CLI startup remains workerless" do
    CLI.start_app()
    refute Process.whereis(IexCode.Runs.RunDispatcher)
    refute Process.whereis(IexCode.Kanban.Scheduler)
  end

  test "launch scope reuses a project by path and a valid session", %{workspace_path: path} do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)

    assert {:ok, scope} =
             CLI.resolve_launch_context(project: path, session: session.id)

    assert scope.project.id == project.id
    assert scope.session.id == session.id
  end

  test "launch scope rejects a session/project mismatch", %{workspace_path: path} do
    first = create_project_fixture(%{root_path: path})
    second_path = create_temp_workspace()
    second = create_project_fixture(%{root_path: second_path})
    session = create_session_fixture(first)
    on_exit(fn -> File.rm_rf(second_path) end)

    assert {:error, :session_project_mismatch} =
             CLI.resolve_launch_context(project: second.id, session: session.id)
  end

  test "mix iex_code.run uses the shared router and prints bounded JSON", %{
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    request_key = "cli-task-#{Ecto.UUID.generate()}"
    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)

    on_exit(fn -> Mix.shell(previous_shell) end)

    Mix.Tasks.IexCode.Run.run([
      "--project",
      project.id,
      "--session",
      session.id,
      "--request-key",
      request_key,
      "--priority",
      "high",
      "--max-attempts",
      "5",
      "--token-budget",
      "12000",
      "--cost-budget-cents",
      "900",
      "--time-budget-minutes",
      "30",
      "--agent-max-turns",
      "12",
      "--json",
      "/run",
      "inspect",
      "the",
      "workspace"
    ])

    assert_receive {:mix_shell, :info, [json]}
    payload = Jason.decode!(json)
    assert payload["kind"] == "coding_agent"
    assert payload["mode"] == "single"
    assert payload["request_key"] == request_key
    assert payload["priority"] == "high"
    assert payload["max_attempts"] == 5
    refute Map.has_key?(payload, "metadata")

    run = Runs.get_run_by_request_key(session.id, request_key)
    assert run.id == payload["id"]
    assert run.token_budget == 12_000
    assert run.cost_budget_cents == 900
    assert run.time_budget_ms == 1_800_000
    assert run.metadata["execution_policy"]["agent_max_turns"] == 12
  end

  test "CLI formatting never serializes run metadata or credentials", %{workspace_path: path} do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)

    {:ok, run} =
      Runs.create_run(%{
        project_id: project.id,
        session_id: session.id,
        objective: "Safe summary",
        kind: "analysis",
        mode: "single",
        metadata: %{"api_key" => "never-print-this"}
      })

    json = CLI.run_json(run) |> Jason.encode!()
    refute json =~ "never-print-this"
    refute json =~ "metadata"
  end

  test "runs and control tasks expose bounded secret-free status JSON", %{workspace_path: path} do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)

    {:ok, run} =
      Runs.create_run(%{
        project_id: project.id,
        session_id: session.id,
        objective: "Inspect status",
        kind: "analysis",
        mode: "single",
        metadata: %{"secret" => "never-list-this"}
      })

    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(previous_shell) end)

    Mix.Tasks.IexCode.Runs.run(["--session", session.id, "--limit", "1", "--json"])
    assert_receive {:mix_shell, :info, [list_json]}
    assert [%{"id" => listed_id}] = Jason.decode!(list_json)
    assert listed_id == run.id
    refute list_json =~ "never-list-this"

    Mix.Tasks.IexCode.Control.run(["--json", run.id, "status"])
    assert_receive {:mix_shell, :info, [status_json]}

    assert %{"id" => status_id, "action" => "status", "status" => "queued"} =
             Jason.decode!(status_json)

    assert status_id == run.id
    refute status_json =~ "never-list-this"
  end

  test "run task leaves slash-command options for the shared command parser", %{
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(previous_shell) end)

    Mix.Tasks.IexCode.Run.run([
      "--project",
      project.id,
      "--session",
      session.id,
      "--swarm-agents",
      "8",
      "--swarm-retries",
      "4",
      "/goal",
      "--draft",
      "Review",
      "the",
      "release"
    ])

    assert_receive {:mix_shell, :info, [output]}
    [run] = Runs.list_runs(session_id: session.id, limit: 1)
    assert run.status == "draft"
    assert run.metadata["goal_title"] == "Review the release"
    assert run.metadata["execution_policy"]["swarm_agent_count"] == 8
    assert run.metadata["execution_policy"]["swarm_max_retries"] == 4
    assert output =~ run.id

    Mix.Tasks.IexCode.Run.run([
      "--project",
      project.id,
      "--session",
      session.id,
      "--max-attempts",
      "1",
      "/research",
      "--level",
      "low",
      "Compare",
      "the",
      "queues"
    ])

    assert_receive {:mix_shell, :info, [research_output]}

    research_run =
      Runs.list_runs(session_id: session.id, limit: 2)
      |> Enum.find(&(&1.kind == "deep_research"))

    assert research_run
    assert research_run.kind == "deep_research"
    assert research_run.max_attempts == 1
    assert research_run.metadata["research"]["level"] == "low"
    assert research_output =~ research_run.id
  end

  test "run task prints shared slash help without launching work", %{workspace_path: path} do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(previous_shell) end)

    Mix.Tasks.IexCode.Run.run([
      "--project",
      project.id,
      "--session",
      session.id,
      "/help"
    ])

    assert_receive {:mix_shell, :info, [output]}
    assert output =~ "/goal"
    assert output =~ "/research"
    assert output =~ "/goal [--draft] <objective>"
    assert output =~ "/research [--level low|medium|high|ultra] <objective>"
    assert Runs.list_runs(session_id: session.id) == []
  end

  test "help is pure from an unregistered directory and still rejects arguments" do
    root =
      Path.join(
        System.tmp_dir!(),
        "iex-code-pure-help-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    before_counts = {
      Repo.aggregate(Project, :count),
      Repo.aggregate(Session, :count),
      Repo.aggregate(Run, :count)
    }

    assert IexCode.Projects.get_project_by_path(root) == nil

    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(previous_shell) end)

    File.cd!(root, fn -> Mix.Tasks.IexCode.Run.run(["/help"]) end)

    assert_receive {:mix_shell, :info, [output]}
    assert output =~ "/goal [--draft] <objective>"
    assert output =~ "/research [--level low|medium|high|ultra] <objective>"
    assert IexCode.Projects.get_project_by_path(root) == nil

    assert {
             Repo.aggregate(Project, :count),
             Repo.aggregate(Session, :count),
             Repo.aggregate(Run, :count)
           } == before_counts

    assert_raise Mix.Error, ~r{/help does not accept arguments}, fn ->
      File.cd!(root, fn -> Mix.Tasks.IexCode.Run.run(["/help", "unexpected"]) end)
    end

    assert {
             Repo.aggregate(Project, :count),
             Repo.aggregate(Session, :count),
             Repo.aggregate(Run, :count)
           } == before_counts
  end

  test "ordinary CLI text honors the configured typed DAG default", %{workspace_path: path} do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)

    assert {:ok, _settings} =
             IexCode.Settings.update_settings(%{
               default_dispatch_mode: "background",
               default_run_mode: "dag"
             })

    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(previous_shell) end)

    Mix.Tasks.IexCode.Run.run([
      "--project",
      project.id,
      "--session",
      session.id,
      "inspect",
      "the",
      "project",
      "structure"
    ])

    assert_receive {:mix_shell, :info, [output]}

    [run] = Runs.list_runs(session_id: session.id, limit: 1)
    assert run.execution_engine == "dag_v1"
    assert run.metadata["dag_template"] == "ordinary_background_v1"
    assert output =~ run.id
  end

  test "ordinary CLI text explains when the configured default is interactive", %{
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)

    assert {:ok, _settings} =
             IexCode.Settings.update_settings(%{default_dispatch_mode: "interactive"})

    assert_raise Mix.Error, ~r/ordinary text may resolve to Interactive in Settings/, fn ->
      Mix.Tasks.IexCode.Run.run([
        "--project",
        project.id,
        "--session",
        session.id,
        "inspect the project"
      ])
    end

    assert Runs.list_runs(session_id: session.id) == []
  end

  test "research rejects a whole-run retry override before enqueue", %{workspace_path: path} do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)

    assert_raise Mix.Error, ~r/--max-attempts must be 1 for \/research/, fn ->
      Mix.Tasks.IexCode.Run.run([
        "--project",
        project.id,
        "--session",
        session.id,
        "--max-attempts",
        "2",
        "/research",
        "compare queue designs"
      ])
    end

    assert Runs.list_runs(session_id: session.id) == []
  end

  test "control start is scoped to drafts and rejects a non-draft run", %{workspace_path: path} do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)

    {:ok, draft} =
      IexCode.Execution.Router.route(
        "/goal --draft start this after review",
        %{
          project_id: project.id,
          session_id: session.id,
          settings: IexCode.Settings.get_settings(),
          request_key: "cli-start-#{Ecto.UUID.generate()}",
          source: "cli_test"
        }
      )

    draft_run = draft.run

    start_supervised!(
      {IexCode.Runs.RunDispatcher,
       name: IexCode.Runs.RunDispatcher,
       executor: IexCode.RunDispatcherTestExecutor,
       max_concurrency: 1,
       poll_interval: 60_000,
       heartbeat_interval: 60_000}
    )

    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(previous_shell) end)

    Mix.Tasks.IexCode.Control.run([draft_run.id, "start"])
    assert_receive {:mix_shell, :info, [output]}
    assert output =~ "start: #{draft_run.id}"
    assert Runs.get_run!(draft_run.id).status in ["queued", "running"]

    assert_raise Mix.Error, ~r/invalid_transition/, fn ->
      Mix.Tasks.IexCode.Control.run([draft_run.id, "start"])
    end
  end

  test "pending CLI controls are applied by the durable owner poll, not the caller", %{
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)

    Process.register(self(), IexCode.RunDispatcherTestReceiver)

    on_exit(fn ->
      if Process.whereis(IexCode.RunDispatcherTestReceiver) == self(),
        do: Process.unregister(IexCode.RunDispatcherTestReceiver)
    end)

    dispatcher =
      start_supervised!(
        {IexCode.Runs.RunDispatcher,
         name: IexCode.Runs.RunDispatcher,
         executor: IexCode.RunDispatcherTestExecutor,
         max_concurrency: 1,
         poll_interval: 60_000,
         heartbeat_interval: 60_000}
      )

    assert {:ok, queued} =
             IexCode.Runs.RunDispatcher.enqueue(%{
               project_id: project.id,
               session_id: session.id,
               objective: "Wait for offline controls",
               kind: "coding_agent",
               mode: "single"
             })

    assert_receive {:test_run_started, run_id, _worker}, 5_000
    assert run_id == queued.id

    running = Runs.get_run!(run_id)
    pause_key = "cli-pause-#{Ecto.UUID.generate()}"
    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(previous_shell) end)

    Mix.Tasks.IexCode.Control.run(["--request-key", pause_key, run_id, "pause"])
    assert_receive {:mix_shell, :info, [pause_output]}
    assert pause_output =~ pause_key

    pause =
      running
      |> Runs.list_controls()
      |> Enum.find(&(&1.idempotency_key == pause_key))

    assert pause.status == "pending"

    Mix.Tasks.IexCode.Control.run(["--request-key", pause_key, run_id, "pause"])
    assert_receive {:mix_shell, :info, [_replay_output]}

    replayed_pause =
      running
      |> Runs.list_controls()
      |> Enum.find(&(&1.idempotency_key == pause_key))

    assert replayed_pause.id == pause.id
    send(dispatcher, :poll)
    _ = :sys.get_state(dispatcher)
    assert Runs.get_run!(run_id).status == "paused"
    assert Runs.get_control(pause.id).status == "applied"

    assert {:ok, {_run, resume}} =
             CLI.enqueue_run_control(
               Runs.get_run!(run_id),
               "resume",
               %{},
               "cli-resume-#{Ecto.UUID.generate()}"
             )

    send(dispatcher, :poll)
    _ = :sys.get_state(dispatcher)
    assert Runs.get_run!(run_id).status == "running"
    assert Runs.get_control(resume.id).status == "applied"

    guidance = "Honor the cross-BEAM steering receipt"

    assert {:ok, {_run, steer}} =
             CLI.enqueue_run_control(
               Runs.get_run!(run_id),
               "steer",
               %{"guidance" => guidance},
               "cli-steer-#{Ecto.UUID.generate()}"
             )

    send(dispatcher, :poll)
    assert_receive {:test_run_steered, ^run_id, ^guidance}, 5_000
    assert Runs.get_control(steer.id).status == "applied"

    assert {:ok, _requested} = Runs.request_cancellation(run_id, "local-cli")
    send(dispatcher, :heartbeat)
    assert_receive {:test_run_cancelled, ^run_id}, 5_000
    _ = :sys.get_state(dispatcher)
    assert Runs.get_run!(run_id).status == "cancelled"
  end

  test "daemon preserves FIFO when steering precedes pause", %{workspace_path: path} do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    Process.register(self(), IexCode.RunDispatcherTestReceiver)

    on_exit(fn ->
      if Process.whereis(IexCode.RunDispatcherTestReceiver) == self(),
        do: Process.unregister(IexCode.RunDispatcherTestReceiver)
    end)

    dispatcher =
      start_supervised!(
        {IexCode.Runs.RunDispatcher,
         name: IexCode.Runs.RunDispatcher,
         executor: IexCode.RunDispatcherTestExecutor,
         max_concurrency: 1,
         poll_interval: 60_000,
         heartbeat_interval: 60_000}
      )

    assert {:ok, queued} =
             IexCode.Runs.RunDispatcher.enqueue(%{
               project_id: project.id,
               session_id: session.id,
               objective: "Preserve external control order",
               kind: "coding_agent",
               mode: "single"
             })

    assert_receive {:test_run_started, run_id, _worker}, 5_000
    assert run_id == queued.id
    running = Runs.get_run!(run_id)

    assert {:ok, {_run, steer}} =
             CLI.enqueue_run_control(
               running,
               "steer",
               %{"guidance" => "steer before pause"},
               "ordered-steer-#{Ecto.UUID.generate()}"
             )

    assert {:ok, {_run, pause}} =
             CLI.enqueue_run_control(
               running,
               "pause",
               %{},
               "ordered-pause-#{Ecto.UUID.generate()}"
             )

    send(dispatcher, :poll)
    assert_receive {:test_run_steered, ^run_id, "steer before pause"}, 5_000
    _ = :sys.get_state(dispatcher)
    assert Runs.get_control(steer.id).status == "applied"
    assert Runs.get_control(pause.id).status == "pending"
    assert Runs.get_run!(run_id).status == "running"

    send(dispatcher, :poll)
    _ = :sys.get_state(dispatcher)
    assert Runs.get_control(pause.id).status == "applied"
    assert Runs.get_run!(run_id).status == "paused"
  end

  test "offline steering rejects typed DAGs before a control is inserted" do
    forged_dag = %{
      id: Ecto.UUID.generate(),
      status: "running",
      execution_engine: "dag_v1",
      kind: "analysis"
    }

    assert {:error, :dag_steering_unsupported} =
             CLI.enqueue_run_control(forged_dag, "steer", %{"guidance" => "not supported"})
  end

  test "offline draft start validates its persisted manifest", %{workspace_path: path} do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)

    assert {:ok, draft} =
             IexCode.Runs.RunDispatcher.create_draft(%{
               project_id: project.id,
               session_id: session.id,
               objective: "Validate before start",
               kind: "coding_agent",
               mode: "single"
             })

    assert {:ok, queued} = IexCode.Runs.RunDispatcher.start_draft_offline(draft)
    assert queued.status == "queued"

    assert {:error, {:invalid_transition, "queued", "queued"}} =
             IexCode.Runs.RunDispatcher.start_draft_offline(queued)

    assert {:ok, corrupt} =
             IexCode.Runs.RunDispatcher.create_draft(%{
               project_id: project.id,
               session_id: session.id,
               objective: "Corrupt before start",
               kind: "coding_agent",
               mode: "single"
             })

    [step | _] = Runs.list_steps(corrupt)

    {1, _} =
      from(candidate in IexCode.Runs.RunStep, where: candidate.id == ^step.id)
      |> IexCode.Repo.update_all(set: [kind: ""])

    assert {:error, _reason} = IexCode.Runs.RunDispatcher.start_draft_offline(corrupt)
    assert Runs.get_run!(corrupt.id).status == "draft"
  end

  test "run task rejects policy overrides outside the shared bounds before insertion", %{
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)

    invalid_cases = [
      ["--priority", "urgent"],
      ["--max-attempts", "0"],
      ["--token-budget", "0"],
      ["--cost-budget-cents", "10000001"],
      ["--time-budget-minutes", "10081"],
      ["--agent-max-turns", "21"],
      ["--swarm-agents", "3"],
      ["--swarm-retries", "11"]
    ]

    for invalid <- invalid_cases do
      assert_raise Mix.Error, fn ->
        Mix.Tasks.IexCode.Run.run(
          ["--project", project.id, "--session", session.id] ++
            invalid ++ ["/run", "must not launch"]
        )
      end
    end

    assert Runs.list_runs(session_id: session.id) == []
  end
end
