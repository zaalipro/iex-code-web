defmodule IexCode.Execution.RouterTest do
  use IexCode.E2E.Case, async: false

  alias IexCode.Execution.{CommandParser, Intent, PolicyError, Router}
  alias IexCode.{Runs, Sessions, Settings}

  setup %{workspace_path: path} do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    settings = Settings.get_settings()

    {:ok,
     project: project,
     session: session,
     settings: settings,
     context: %{
       project_id: project.id,
       session_id: session.id,
       settings: settings,
       overrides: %{},
       request_key: nil
     }}
  end

  test "ordinary policy dispatch and explicit chat share one typed intake", %{context: context} do
    assert {:ok, interactive} =
             Router.route("explain this project", %{
               context
               | overrides: %{dispatch_mode: "interactive"}
             })

    assert {:interactive, "explain this project", opts} = interactive.action
    assert opts[:allowed_tools] == interactive.execution_policy["allowed_tools"]
    assert interactive.request_key == nil

    assert {:ok, forced_interactive} = Router.route("/ask explain this project", context)
    assert {:interactive, "explain this project", _opts} = forced_interactive.action

    assert {:ok, durable} =
             Router.route("explain this project", %{
               context
               | overrides: %{dispatch_mode: "background", run_mode: "single"}
             })

    assert {:run, run} = durable.action
    assert run.kind == "coding_agent"
    assert run.mode == "single"
  end

  test "durable policy identity is not minted from volatile settings", %{context: context} do
    volatile = %IexCode.Settings.AppSettings{}

    assert {:error, :settings_unavailable} =
             Router.route("/run refuse volatile route identity", %{context | settings: volatile})
  end

  test "ordinary background text honors shared DAG and research defaults", %{context: context} do
    dag_context = %{
      context
      | request_key: "ordinary-dag-#{Ecto.UUID.generate()}",
        overrides: %{dispatch_mode: "background", run_mode: "dag"}
    }

    assert {:ok, %{action: {:run, dag_run}}} =
             Router.route("inspect the project structure", dag_context)

    assert dag_run.execution_engine == "dag_v1"
    assert dag_run.kind == "analysis"
    assert dag_run.mode == "workflow"
    assert dag_run.metadata["dag_template"] == "ordinary_background_v1"

    # dag_v1 canonicalizes by stable step key before assigning positions; input
    # list order is deliberately not the persisted ordering contract.
    assert Enum.map(Runs.list_steps(dag_run), &{&1.position, &1.key, &1.kind}) == [
             {0, "aggregate", "aggregate"},
             {1, "inventory", "project_inventory"},
             {2, "read_project", "read_file"},
             {3, "read_readme", "read_file"}
           ]

    research_context =
      context
      |> Map.put(:request_key, "ordinary-research-#{Ecto.UUID.generate()}")
      |> Map.put(:overrides, %{dispatch_mode: "background", run_mode: "research"})
      |> Map.put(:research, %{
        level: "low",
        ranked_providers: ["duckduckgo"],
        max_sources: 4,
        fetch_parallelism: 2,
        require_conflict_audit: true
      })

    assert {:ok, %{action: {:run, research_run}, intent: intent}} =
             Router.route("compare the queue designs", research_context)

    assert intent.kind == :research
    assert research_run.execution_engine == "dag_v1"
    assert research_run.kind == "deep_research"
    assert research_run.metadata["research"]["level"] == "low"
  end

  test "durable /run has a stable policy snapshot, one message, and idempotent replay", %{
    context: context,
    session: session
  } do
    request_key = "router-run-#{Ecto.UUID.generate()}"

    context =
      context
      |> Map.put(:request_key, request_key)
      |> Map.put(:source, "cli")
      |> Map.put(:metadata, %{
        "safe_tag" => "keep",
        "api_key" => "must-not-persist",
        "nested" => %{"base_url" => "https://must-not-persist.example", "safe" => true}
      })
      |> Map.put(:overrides, %{
        priority: "high",
        max_attempts: 5,
        token_budget: 12_000,
        time_budget_minutes: 7,
        agent_max_turns: 4
      })

    assert {:ok, first} = Router.route("/run inspect and patch safely", context)
    assert {:run, run} = first.action
    refute first.replayed?
    assert first.request_key == request_key
    assert run.request_key == request_key
    assert run.priority == "high"
    assert run.max_attempts == 5
    assert run.token_budget == 12_000
    assert run.time_budget_ms == 420_000
    assert run.metadata["safe_tag"] == "keep"
    assert run.metadata["nested"] == %{"safe" => true}
    refute inspect(run.metadata) =~ "must-not-persist"

    policy = run.metadata["execution_policy"]
    assert policy["version"] == 1
    assert policy["agent_max_turns"] == 4
    refute Map.has_key?(policy, "openai_api_key")
    refute Map.has_key?(policy, "openai_base_url")

    assert {:ok, replay} = Router.route("/run inspect and patch safely", context)
    assert replay.run.id == run.id
    assert replay.replayed?

    launch_messages =
      Sessions.list_messages(session.id)
      |> Enum.filter(&(get_in(&1.metadata || %{}, ["run_id"]) == run.id))

    assert length(launch_messages) == 1
    assert hd(launch_messages).metadata["intent"] == "run"
  end

  test "a reused request key with different semantics fails closed", %{context: context} do
    context = Map.put(context, :request_key, "router-conflict-#{Ecto.UUID.generate()}")

    assert {:ok, _result} = Router.route("/run first objective", context)
    assert {:error, :request_key_conflict} = Router.route("/run different objective", context)
  end

  test "concurrent identical durable intake creates one run and one canonical user turn", %{
    context: context,
    session: session
  } do
    request_key = "router-concurrent-#{Ecto.UUID.generate()}"
    context = Map.put(context, :request_key, request_key)

    results =
      1..12
      |> Task.async_stream(fn _index -> Router.route("/run prove atomic intake", context) end,
        max_concurrency: 12,
        ordered: false,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(results, &match?({:ok, %{run: %IexCode.Runs.Run{}}}, &1))
    run_ids = Enum.map(results, fn {:ok, result} -> result.run.id end)
    assert [run_id] = Enum.uniq(run_ids)

    messages =
      session.id
      |> Sessions.list_messages()
      |> Enum.filter(&(&1.idempotency_key == "run-user:#{run_id}"))

    assert [%{role: "user", metadata: %{"run_id" => ^run_id}}] = messages
  end

  test "goal form intent and slash goal use the same durable goal contract", %{
    context: context
  } do
    slash_context =
      context
      |> Map.put(:request_key, "slash-goal-#{Ecto.UUID.generate()}")
      |> Map.put(:goal_title, "Ship router")
      |> Map.put(:goal_description, "Prove intake parity")

    assert {:ok, slash} = Router.route("/goal ignored fallback title", slash_context)
    assert {:run, slash_run} = slash.action

    {:ok, typed_intent} = CommandParser.parse("/goal ignored fallback title", source: "goal_form")

    typed_context =
      context
      |> Map.put(:request_key, "form-goal-#{Ecto.UUID.generate()}")
      |> Map.put(:goal_title, "Ship router")
      |> Map.put(:goal_description, "Prove intake parity")

    assert {:ok, typed} = Router.route(typed_intent, typed_context)
    assert {:run, typed_run} = typed.action

    for run <- [slash_run, typed_run] do
      assert run.kind == "coding_swarm"
      assert run.mode == "swarm"
      assert run.metadata["source"] == "autonomous_goal"
      assert run.metadata["goal_request_id"] == run.request_key
      assert run.metadata["goal_title"] == "Ship router"
      assert run.metadata["goal_description"] == "Prove intake parity"
      assert run.metadata["goal_auto_start"]
      assert run.objective =~ "Detailed instructions and acceptance criteria"
    end

    assert slash_run.metadata["execution_policy"] == typed_run.metadata["execution_policy"]
  end

  test "goal draft and policy auto-start false both create durable drafts", %{context: context} do
    assert {:ok, explicit} =
             Router.route("/goal --draft preserve this", %{
               context
               | request_key: "explicit-draft-#{Ecto.UUID.generate()}"
             })

    assert {:draft, explicit_run} = explicit.action
    assert explicit_run.status == "draft"
    refute explicit_run.metadata["goal_auto_start"]

    assert {:ok, configured} =
             Router.route("/goal preserve that", %{
               context
               | request_key: "configured-draft-#{Ecto.UUID.generate()}",
                 overrides: %{goal_auto_start: false}
             })

    assert {:draft, configured_run} = configured.action
    assert configured_run.status == "draft"
  end

  test "research delegates the exact launch service with the same request identity", %{
    context: context
  } do
    request_key = "router-research-#{Ecto.UUID.generate()}"

    context =
      context
      |> Map.put(:request_key, request_key)
      |> Map.put(:research, %{
        level: "low",
        ranked_providers: ["duckduckgo"],
        max_sources: 6,
        fetch_parallelism: 2,
        require_conflict_audit: true
      })

    assert {:ok, result} = Router.route("/research compare durable intake", context)
    assert {:run, run} = result.action
    assert run.kind == "deep_research"
    assert run.mode == "research"
    assert run.execution_engine == "dag_v1"
    assert run.request_key == request_key
    assert run.metadata["execution_policy"]["version"] == 1
    assert run.metadata["research"]["level"] == "low"
  end

  test "scope and request-key validation fail before persistence", %{
    context: context,
    project: project,
    workspace_path: path
  } do
    other_session = create_session_fixture(project)
    other_path = Path.join(path, "foreign")
    File.mkdir_p!(other_path)
    other_project = create_project_fixture(%{root_path: other_path})

    assert {:error, :session_project_mismatch} =
             Router.route("/run invalid scope", %{
               context
               | project_id: other_project.id,
                 session_id: other_session.id
             })

    assert {:error, :invalid_request_key} =
             Router.route("/run invalid key", %{context | request_key: "has whitespace"})

    assert Runs.list_runs(session_id: other_session.id) == []
  end

  test "a model identifier over 240 bytes is rejected before durable enqueue", %{
    context: context
  } do
    assert {:error, %PolicyError{code: :invalid_override, field: "model_name"}} =
             Router.route("/run invalid oversized model", %{
               context
               | overrides: %{model_name: String.duplicate("m", 241)}
             })

    assert Runs.list_runs(session_id: context.session_id) == []
  end

  test "forged typed intent semantics fail before persistence", %{context: context} do
    forged = %Intent{
      kind: :goal,
      objective: "Must not become an interactive goal",
      durability: :interactive,
      mode: :single,
      draft?: false,
      raw_command: nil,
      source: "forged"
    }

    assert {:error, :invalid_execution_intent} = Router.route(forged, context)
    assert Runs.list_runs(session_id: context.session_id) == []
  end
end
