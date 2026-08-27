defmodule IexCode.RunsTest do
  use IexCode.DataCase, async: false

  import Ecto.Query

  alias IexCode.{Projects, Repo, Runs, Sessions}
  alias IexCode.Runs.Run

  setup do
    root = Path.join(System.tmp_dir!(), "iex-code-runs-#{System.unique_integer([:positive])}")
    {:ok, project} = Projects.create_project(%{name: "Runs Test", root_path: root})
    {:ok, session} = Sessions.create_session(%{project_id: project.id, title: "Durable run"})

    %{project: project, session: session}
  end

  defp create_run(project, session, attrs \\ %{}) do
    base = %{
      project_id: project.id,
      session_id: session.id,
      objective: "Implement a durable async executor"
    }

    Runs.create_run(Map.merge(base, attrs))
  end

  defp worker_opts(run, owner) do
    [
      lease_owner: owner,
      run_attempt: run.attempt,
      lease_generation: run.lease_generation
    ]
  end

  defp insert_forged_dag(project, session, objective) do
    %Run{project_id: project.id, session_id: session.id}
    |> Run.create_changeset(%{
      objective: objective,
      kind: "analysis",
      mode: "single",
      execution_engine: "dag_v1",
      manifest_hash: String.duplicate("0", 64)
    })
    |> Repo.insert()
  end

  defp dag_steps do
    [
      %{key: "inventory", kind: "project_inventory", title: "Inventory"},
      %{
        key: "join",
        kind: "aggregate",
        title: "Join",
        depends_on: ["inventory"]
      }
    ]
  end

  test "creation commits a sequence-one event before broadcasting on run and session topics", %{
    project: project,
    session: session
  } do
    :ok = Runs.subscribe_session(session.id)
    {:ok, run} = create_run(project, session)
    :ok = Runs.subscribe(run.id)

    assert run.status == "queued"
    assert run.event_sequence == 1
    assert [%{sequence: 1, type: "run.created"}] = Runs.list_events(run.id)
    assert %{sequence: 1} = Runs.latest_event(run)
    run_id = run.id
    assert_receive {:run_created, %{id: ^run_id}}
    assert_receive {:run_event, %{run_id: ^run_id, sequence: 1}}
  end

  test "run and initial steps become visible atomically", %{project: project, session: session} do
    attrs = %{
      project_id: project.id,
      session_id: session.id,
      objective: "Atomic graph"
    }

    assert {:ok, run} =
             Runs.create_run_with_steps(attrs, [
               %{key: "prepare-0", kind: "prepare", title: "Prepare", position: 0},
               %{
                 key: "execute-0",
                 kind: "execute",
                 title: "Execute",
                 position: 1,
                 depends_on: ["prepare-0"]
               }
             ])

    assert Enum.map(Runs.list_steps(run), & &1.key) == ["prepare-0", "execute-0"]

    assert Enum.map(Runs.list_events(run), & &1.type) == [
             "run.created",
             "run.step_created",
             "run.step_created"
           ]

    assert Runs.get_run!(run.id).event_sequence == 3
  end

  test "step summaries omit body-bearing params and results", %{
    project: project,
    session: session
  } do
    attrs = %{
      project_id: project.id,
      session_id: session.id,
      objective: "Bounded lifecycle projection"
    }

    assert {:ok, run} =
             Runs.create_run_with_steps(attrs, [
               %{
                 key: "bounded-step",
                 kind: "prepare",
                 title: "Bounded step",
                 params: %{"body" => String.duplicate("p", 100_000)}
               }
             ])

    [step] = Runs.list_steps(run)

    assert {:ok, _completed} =
             Runs.transition_step(step, "completed", %{
               progress: 100,
               result: %{"body" => String.duplicate("r", 100_000)}
             })

    [summary] = Runs.list_step_summaries(run)
    assert summary.id == step.id
    assert summary.status == "completed"
    assert summary.progress == 100
    assert summary.params == %{}
    assert is_nil(summary.result)
  end

  test "session-scoped request keys make creation durable and idempotent", %{
    project: project,
    session: session
  } do
    request_key = Ecto.UUID.generate()

    attrs = %{
      project_id: project.id,
      session_id: session.id,
      request_key: request_key,
      objective:
        "Ship the durable goal\n\nDetailed instructions and acceptance criteria:\nKeep all detail",
      metadata: %{
        "source" => "autonomous_goal",
        "goal_title" => "Ship the durable goal",
        "goal_description" => "Keep all detail"
      }
    }

    assert {:ok, first} = Runs.create_run(attrs)
    assert {:ok, duplicate} = Runs.create_run(attrs)
    assert duplicate.id == first.id
    assert duplicate.request_key == request_key
    assert first.request_fingerprint =~ ~r/^[0-9a-f]{64}$/
    assert duplicate.request_fingerprint == first.request_fingerprint
    assert duplicate.metadata["goal_title"] == "Ship the durable goal"
    assert duplicate.metadata["goal_description"] == "Keep all detail"
    assert [%{type: "run.created"}] = Runs.list_events(first)
    assert [persisted] = Runs.list_runs(session_id: session.id)
    assert persisted.id == first.id

    assert {:error, :request_key_conflict} =
             attrs
             |> Map.put(:objective, "A different operation cannot reuse the request key")
             |> Runs.create_run()

    assert {:error, :request_key_conflict} =
             attrs
             |> Map.put(:status, "draft")
             |> Runs.create_run()

    assert {:error, %Ecto.Changeset{} = changeset} =
             first
             |> Run.changeset(%{request_key: Ecto.UUID.generate()})
             |> Repo.update()

    assert {"cannot be changed after creation", _metadata} = changeset.errors[:request_key]

    assert {:error, %Ecto.Changeset{} = fingerprint_changeset} =
             first
             |> Run.changeset(%{request_fingerprint: String.duplicate("f", 64)})
             |> Repo.update()

    assert {"cannot be changed after creation", _metadata} =
             fingerprint_changeset.errors[:request_fingerprint]

    {:ok, progressed} =
      Runs.transition_run(first, "paused", %{
        priority: "critical",
        metadata: Map.put(first.metadata, "worker_result", %{"changed" => true})
      })

    assert progressed.priority == "critical"
    assert {:ok, replayed} = Runs.create_run(attrs)
    assert replayed.id == first.id
    assert replayed.priority == "critical"
    assert replayed.metadata["worker_result"] == %{"changed" => true}
  end

  test "concurrent creation with one request key returns exactly one run", %{
    project: project,
    session: session
  } do
    request_key = Ecto.UUID.generate()

    attrs = %{
      project_id: project.id,
      session_id: session.id,
      request_key: request_key,
      objective: "Exactly-once concurrent goal"
    }

    results =
      1..12
      |> Task.async_stream(
        fn _ -> Runs.create_run(attrs) end,
        max_concurrency: 12,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(results, &match?({:ok, %Run{}}, &1))
    assert results |> Enum.map(fn {:ok, run} -> run.id end) |> Enum.uniq() |> length() == 1
    assert [%Run{request_key: ^request_key}] = Runs.list_runs(session_id: session.id)
  end

  test "request keys are nullable and unique only within a session", %{
    project: project,
    session: session
  } do
    {:ok, second_session} =
      Sessions.create_session(%{project_id: project.id, title: "Second durable run session"})

    assert {:ok, first_without_key} = create_run(project, session, %{objective: "No key one"})
    assert {:ok, second_without_key} = create_run(project, session, %{objective: "No key two"})
    refute first_without_key.id == second_without_key.id

    attrs = %{
      project_id: project.id,
      request_key: "same-browser-request",
      objective: "Scoped key"
    }

    assert {:ok, first_session_run} =
             Runs.create_run(Map.put(attrs, :session_id, session.id))

    assert {:ok, second_session_run} =
             Runs.create_run(Map.put(attrs, :session_id, second_session.id))

    refute first_session_run.id == second_session_run.id
  end

  test "durable DAG creation rejects empty graphs and persists a canonical hash", %{
    project: project,
    session: session
  } do
    assert {:error, :empty_dag_manifest} =
             create_run(project, session, %{execution_engine: "dag_v1"})

    assert Runs.list_runs(session_id: session.id) == []

    attrs = %{
      project_id: project.id,
      session_id: session.id,
      objective: "Canonical DAG",
      kind: "analysis",
      mode: "workflow",
      execution_engine: "dag_v1"
    }

    assert {:ok, run} = Runs.create_run_with_steps(attrs, Enum.reverse(dag_steps()))
    assert byte_size(run.manifest_hash) == 64
    assert Enum.map(Runs.list_steps(run), & &1.key) == ["inventory", "join"]
    assert Enum.map(Runs.list_steps(run), & &1.status) == ["ready", "pending"]
  end

  test "durable creation validates the legacy manifest before any insert", %{
    project: project,
    session: session
  } do
    attrs = %{
      project_id: project.id,
      session_id: session.id,
      objective: "Duplicate graph"
    }

    assert {:error, :duplicate_step_key} =
             Runs.create_run_with_steps(attrs, [
               %{key: "duplicate", kind: "prepare", title: "First"},
               %{key: "duplicate", kind: "execute", title: "Second"}
             ])

    assert Runs.list_runs(session_id: session.id) == []
  end

  test "run execution manifest is immutable through lifecycle and heartbeat updates", %{
    project: project,
    session: session
  } do
    {:ok, run} = create_run(project, session)

    assert {:error, %Ecto.Changeset{} = transition_changeset} =
             Runs.transition_run(run, "running", %{execution_engine: "dag_v1"})

    assert {"cannot be changed after creation", _} =
             transition_changeset.errors[:execution_engine]

    assert {:error, %Ecto.Changeset{} = heartbeat_changeset} =
             Runs.heartbeat_run(run, %{"execution_engine" => "dag_v1"})

    assert {"cannot be changed after creation", _} =
             heartbeat_changeset.errors[:execution_engine]

    assert {:error, %Ecto.Changeset{} = direct_changeset} =
             run
             |> Run.create_changeset(%{execution_engine: "dag_v1"})
             |> Repo.update()

    assert {"cannot be changed after creation", _} = direct_changeset.errors[:execution_engine]

    for {field, changed} <- [
          {:objective, "Reinterpreted objective"},
          {:kind, "deep_research"},
          {:mode, "research"}
        ] do
      assert {:error, %Ecto.Changeset{} = changeset} =
               Runs.heartbeat_run(run, %{field => changed})

      assert {"cannot be changed after creation", _} = changeset.errors[field]
    end

    persisted = Runs.get_run!(run.id)
    assert persisted.status == "queued"
    assert persisted.objective == run.objective
    assert persisted.kind == run.kind
    assert persisted.mode == run.mode
    assert persisted.execution_engine == "legacy_v1"
    assert persisted.event_sequence == 1
  end

  test "generic step creation cannot mutate a persisted dag manifest", %{
    project: project,
    session: session
  } do
    {:ok, run} = insert_forged_dag(project, session, "immutable graph")

    assert {:error, :dag_manifest_immutable} =
             Runs.create_step(run, %{key: "late", kind: "analysis", title: "Late node"})

    forged_legacy = %{run | execution_engine: "legacy_v1"}

    assert {:error, :dag_manifest_immutable} =
             Runs.create_step(forged_legacy, %{
               key: "forged",
               kind: "analysis",
               title: "Forged node"
             })

    assert Runs.list_steps(run) == []
  end

  test "run claims include canonical dag_v1 work", %{
    project: project,
    session: session
  } do
    attrs = %{
      project_id: project.id,
      session_id: session.id,
      objective: "higher priority dag",
      kind: "analysis",
      mode: "workflow",
      execution_engine: "dag_v1",
      priority: "high"
    }

    {:ok, dag} = Runs.create_run_with_steps(attrs, dag_steps())

    {:ok, legacy} =
      create_run(project, session, %{objective: "dispatchable legacy", priority: "low"})

    assert {:ok, claimed} = Runs.claim_next_run("engine-aware-dispatcher")
    assert claimed.id == dag.id
    assert claimed.execution_engine == "dag_v1"
    assert claimed.lease_generation == 1
    assert Runs.get_run!(legacy.id).status == "queued"

    assert :none = Runs.claim_next_run("second-dispatcher", execution_engines: ["dag_v1"])
  end

  test "DAG retry rejects forged manifest hash drift at the durable boundary", %{
    project: project,
    session: session
  } do
    attrs = %{
      project_id: project.id,
      session_id: session.id,
      objective: "forged retry",
      kind: "analysis",
      mode: "workflow",
      execution_engine: "dag_v1"
    }

    {:ok, run} = Runs.create_run_with_steps(attrs, dag_steps())

    {1, _} =
      from(current in Run, where: current.id == ^run.id)
      |> Repo.update_all(
        set: [
          status: "failed",
          completed_at: DateTime.utc_now(),
          manifest_hash: String.duplicate("0", 64)
        ]
      )

    assert {:error, :manifest_drift} = Runs.retry_run(run)

    assert Runs.get_run!(run.id).status == "failed"
  end

  test "retry rejects an invalid next-attempt manifest before changing the run", %{
    project: project,
    session: session
  } do
    {:ok, run} = create_run(project, session)
    {:ok, failed} = Runs.transition_run(run, "failed")

    assert {:error, :duplicate_step_key} =
             Runs.retry_run(failed,
               steps: [
                 %{key: "retry", kind: "prepare", title: "First"},
                 %{key: "retry", kind: "execute", title: "Second"}
               ]
             )

    persisted = Runs.get_run!(run.id)
    assert persisted.status == "failed"
    assert persisted.event_sequence == 2
    assert Runs.list_steps(run) == []
  end

  test "strict changesets reject malformed runs and invalid transitions", %{
    project: project,
    session: session
  } do
    assert {:error, %Ecto.Changeset{} = changeset} =
             create_run(project, session, %{objective: "", status: "invented", progress: 101})

    refute changeset.valid?
    assert {:ok, run} = create_run(project, session)

    assert {:error, {:invalid_transition, "queued", "unknown"}} =
             Runs.transition_run(run, "unknown")

    assert {:ok, completed} = Runs.transition_run(run, "completed")
    assert completed.progress == 100
    assert completed.completed_at

    assert {:error, {:invalid_transition, "completed", "running"}} =
             Runs.transition_run(completed, "running")
  end

  test "events are monotonic, bounded, filterable and replayable", %{
    project: project,
    session: session
  } do
    {:ok, run} = create_run(project, session)

    assert {:ok, %{sequence: 2}} = Runs.append_event(run, "planner.started", %{"n" => 1})
    assert {:ok, %{sequence: 3}} = Runs.append_event(run, "planner.finished", %{"n" => 2})

    assert [2, 3] ==
             run.id
             |> Runs.list_events(after_sequence: 1)
             |> Enum.map(& &1.sequence)

    assert [2] ==
             run.id
             |> Runs.list_events(after_sequence: 1, type: "planner.started")
             |> Enum.map(& &1.sequence)

    assert [2, 3] == run.id |> Runs.replay_events(2, to_sequence: 3) |> Enum.map(& &1.sequence)

    oversized = %{"value" => String.duplicate("x", 256_001)}
    assert {:error, :payload_too_large} = Runs.append_event(run, "payload.large", oversized)
    assert Runs.latest_event(run).sequence == 3
  end

  test "provider-reported usage accumulates and emits token-budget exhaustion", %{
    project: project,
    session: session
  } do
    {:ok, run} = create_run(project, session, %{token_budget: 100})

    assert {:ok, updated} =
             Runs.record_usage(run, %{prompt_tokens: 30, completion_tokens: 20}, "planner.llm")

    assert updated.input_tokens == 30
    assert updated.output_tokens == 20

    assert {:error, {:token_budget_exhausted, exhausted}} =
             Runs.record_usage(
               run,
               %{"input_tokens" => 40, "output_tokens" => 20},
               "coder.llm"
             )

    assert exhausted.input_tokens == 70
    assert exhausted.output_tokens == 40

    assert Enum.map(Runs.list_events(run), & &1.type) |> Enum.take(-3) == [
             "run.usage_recorded",
             "run.usage_recorded",
             "run.budget_exhausted"
           ]
  end

  test "worker budget exhaustion atomically terminalizes its legacy graph", %{
    project: project,
    session: session
  } do
    attrs = %{
      project_id: project.id,
      session_id: session.id,
      objective: "Budget graph terminalization",
      token_budget: 1
    }

    assert {:ok, _queued} =
             Runs.create_run_with_steps(attrs, [
               %{key: "prepare", kind: "prepare", title: "Prepare", status: "ready"},
               %{
                 key: "execute",
                 kind: "execute",
                 title: "Execute",
                 status: "pending",
                 depends_on: ["prepare"]
               }
             ])

    assert {:ok, claimed} = Runs.claim_next_run("budget-worker", lease_ms: 30_000)
    [execute, prepare] = Runs.list_steps(claimed) |> Enum.sort_by(& &1.kind)
    authority = worker_opts(claimed, "budget-worker")
    assert {:ok, prepare} = Runs.transition_step_worker(prepare, "running", %{}, authority)
    assert {:ok, _prepare} = Runs.transition_step_worker(prepare, "completed", %{}, authority)
    assert {:ok, execute} = Runs.transition_step_worker(execute, "running", %{}, authority)

    original_expiry =
      DateTime.utc_now()
      |> DateTime.add(2, :second)
      |> DateTime.truncate(:second)

    {1, _} =
      from(candidate in Run, where: candidate.id == ^claimed.id)
      |> Repo.update_all(set: [lease_expires_at: original_expiry])

    assert {:error, {:token_budget_exhausted, failed}} =
             Runs.record_usage(claimed, %{input_tokens: 2}, "worker",
               lease_owner: "budget-worker",
               run_attempt: claimed.attempt,
               lease_generation: claimed.lease_generation,
               terminal_lease_ms: 5_000
             )

    assert failed.status == "failed"
    assert DateTime.compare(failed.lease_expires_at, original_expiry) == :gt
    assert Runs.get_step(execute.id).status == "failed"
  end

  test "records total-only provider usage without double counting detailed usage", %{
    project: project,
    session: session
  } do
    {:ok, bounded} = create_run(project, session, %{token_budget: 40})

    assert {:error, {:token_budget_exhausted, exhausted}} =
             Runs.record_usage(bounded, %{"total_tokens" => 50})

    assert exhausted.input_tokens == 50
    assert exhausted.output_tokens == 0

    {:ok, run} = create_run(project, session, %{token_budget: 1_000})

    assert {:ok, total_only} = Runs.record_usage(run, %{"total_tokens" => 50})
    assert total_only.input_tokens == 50
    assert total_only.output_tokens == 0

    assert {:ok, detailed} =
             Runs.record_usage(run, %{
               "prompt_tokens" => 10,
               "completion_tokens" => 5,
               "total_tokens" => 15
             })

    assert detailed.input_tokens == 60
    assert detailed.output_tokens == 5
  end

  test "latest event window keeps new events visible after the journal exceeds 500 entries", %{
    project: project,
    session: session
  } do
    {:ok, run} = create_run(project, session)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    rows =
      for sequence <- 2..511 do
        %{
          id: Ecto.UUID.generate(),
          run_id: run.id,
          sequence: sequence,
          type: "worker.tick",
          source: "worker",
          payload: %{"sequence" => sequence},
          occurred_at: now,
          inserted_at: now
        }
      end

    assert {510, nil} = Repo.insert_all(IexCode.Runs.RunEvent, rows)

    # Forward traversal retains its original oldest-first cursor semantics.
    assert [1, 2, 3] =
             run.id
             |> Runs.list_events(limit: 3)
             |> Enum.map(& &1.sequence)

    tail = Runs.list_latest_events(run, limit: 500)
    assert length(tail) == 500
    assert List.first(tail).sequence == 12
    assert List.last(tail).sequence == 511
    assert Enum.map(tail, & &1.sequence) == Enum.to_list(12..511)
  end

  test "concurrent event writers allocate a gap-free unique sequence", %{
    project: project,
    session: session
  } do
    {:ok, run} = create_run(project, session)

    results =
      1..20
      |> Task.async_stream(
        fn n -> Runs.append_event(run.id, "worker.tick", %{"writer" => n}, "worker") end,
        max_concurrency: 8,
        timeout: :infinity
      )
      |> Enum.to_list()

    assert Enum.all?(results, &match?({:ok, {:ok, _event}}, &1))
    assert Enum.to_list(1..21) == Enum.map(Runs.list_events(run.id), & &1.sequence)
    assert 21 == Runs.get_run!(run.id).event_sequence
  end

  test "steps are ordered, unique by run key, and enforce status transitions", %{
    project: project,
    session: session
  } do
    {:ok, run} = create_run(project, session)

    assert {:ok, second} =
             Runs.create_step(run, %{key: "verify", kind: "verify", title: "Verify", position: 2})

    assert {:ok, first} =
             Runs.create_step(run, %{key: "plan", kind: "plan", title: "Plan", position: 1})

    assert [^first, ^second] = Runs.list_steps(run)

    assert {:error, %Ecto.Changeset{}} =
             Runs.create_step(run, %{key: "plan", kind: "plan", title: "Duplicate"})

    assert {:ok, running} = Runs.transition_step(first, "running", %{attempt: 1})
    assert running.started_at
    assert {:ok, completed} = Runs.transition_step(running, "completed")
    assert completed.progress == 100

    assert {:error, {:invalid_transition, "completed", "running"}} =
             Runs.transition_step(completed, "running")
  end

  test "commands are idempotent and approvals and artifacts are durable", %{
    project: project,
    session: session
  } do
    {:ok, run} = create_run(project, session)

    assert {:ok, command} =
             Runs.enqueue_command(run, "write:lib/example.ex", %{
               tool_name: "write_file",
               arguments: %{"path" => "lib/example.ex"},
               status: "completed",
               attempt: 9,
               output: "forged output",
               error_message: "forged error",
               error_details: %{"credential" => "must not persist"},
               claimed_at: DateTime.utc_now(),
               heartbeat_at: DateTime.utc_now(),
               completed_at: DateTime.utc_now()
             })

    assert command.status == "queued"
    assert command.attempt == 0
    assert is_nil(command.output)
    assert is_nil(command.error_message)
    assert is_nil(command.error_details)
    assert is_nil(command.claimed_at)
    assert is_nil(command.heartbeat_at)
    assert is_nil(command.completed_at)

    assert {:ok, same_command} =
             Runs.enqueue_command(run, "write:lib/example.ex", %{
               tool_name: "write_file",
               arguments: %{"path" => "lib/example.ex"},
               status: "failed",
               attempt: 100,
               error_message: "different ignored lifecycle"
             })

    assert same_command.id == command.id

    assert {:error, :idempotency_conflict} =
             Runs.enqueue_command(run, "write:lib/example.ex", %{
               tool_name: "run_command",
               arguments: %{"command" => "rm -rf /"}
             })

    assert Runs.get_command_by_idempotency_key(run, "write:lib/example.ex").id == command.id

    assert {:ok, approval} =
             Runs.request_approval(run, %{
               key: "approve-write",
               run_command_id: command.id,
               action: "workspace_write",
               resource: "lib/example.ex",
               reason: "The command changes source code"
             })

    assert {:ok, decided} =
             Runs.decide_approval(approval, "approved", %{
               decided_by: "user@example.test",
               decision_note: "Approved"
             })

    assert decided.status == "approved"
    assert decided.decided_at

    assert {:error, {:invalid_transition, "approved", "denied"}} =
             Runs.decide_approval(decided, "denied")

    assert {:ok, artifact} =
             Runs.create_artifact(run, %{
               kind: "patch",
               name: "changes.diff",
               uri: "file:///tmp/changes.diff",
               byte_size: 42
             })

    assert [^artifact] = Runs.list_artifacts(run, kind: "patch")
  end

  test "child references cannot cross their enclosing run", %{
    project: project,
    session: session
  } do
    {:ok, run} = create_run(project, session)
    {:ok, other_run} = create_run(project, session, %{status: "draft"})

    {:ok, step} =
      Runs.create_step(run, %{key: "root", kind: "plan", title: "Root"})

    {:ok, other_step} =
      Runs.create_step(other_run, %{key: "other-root", kind: "plan", title: "Other root"})

    assert {:ok, child} =
             Runs.create_step(run, %{
               key: "child",
               kind: "execute",
               title: "Child",
               parent_step_id: step.id
             })

    assert child.parent_step_id == step.id

    assert {:error, :parent_step_scope_mismatch} =
             Runs.create_step(run, %{
               key: "foreign-child",
               kind: "execute",
               title: "Foreign child",
               parent_step_id: other_step.id
             })

    assert {:error, :parent_step_scope_mismatch} =
             Runs.create_run_with_steps(
               %{
                 project_id: project.id,
                 session_id: session.id,
                 objective: "Atomic cross-run parent rejection"
               },
               [
                 %{
                   key: "foreign-initial-child",
                   kind: "execute",
                   title: "Foreign initial child",
                   parent_step_id: other_step.id
                 }
               ]
             )

    refute Enum.any?(
             Runs.list_runs(session_id: session.id),
             &(&1.objective == "Atomic cross-run parent rejection")
           )

    assert {:error, :run_step_scope_mismatch} =
             Runs.enqueue_command(run, "foreign-step-command", %{
               run_step_id: other_step.id,
               tool_name: "write_file"
             })

    {:ok, other_command} =
      Runs.enqueue_command(other_run, "other-command", %{tool_name: "read_file"})

    assert {:error, :run_command_scope_mismatch} =
             Runs.request_approval(run, %{
               key: "foreign-command-approval",
               run_command_id: other_command.id,
               action: "workspace_write",
               reason: "Must remain run scoped"
             })

    assert {:error, :run_step_scope_mismatch} =
             Runs.create_artifact(run, %{
               run_step_id: other_step.id,
               kind: "patch",
               name: "foreign.diff",
               uri: "file:///tmp/foreign.diff"
             })

    assert {:ok, claimed} = Runs.claim_next_run("artifact-worker", lease_ms: 30_000)
    assert claimed.id == run.id

    assert {:error, :run_step_scope_mismatch} =
             Runs.create_artifact_worker(
               claimed,
               %{
                 run_step_id: other_step.id,
                 kind: "patch",
                 name: "worker-foreign.diff",
                 uri: "file:///tmp/worker-foreign.diff"
               },
               worker_opts(claimed, "artifact-worker")
             )
  end

  test "leased command and approval mutations require exact worker authority", %{
    project: project,
    session: session
  } do
    {:ok, run} = create_run(project, session)
    {:ok, step} = Runs.create_step(run, %{key: "work", kind: "execute", title: "Work"})

    {:ok, stale_approval} =
      Runs.request_approval(run, %{
        key: "before-claim",
        action: "workspace_write",
        reason: "Created before this worker generation"
      })

    assert stale_approval.target_attempt == 0
    assert stale_approval.target_generation == 0
    assert {:ok, claimed} = Runs.claim_next_run("command-worker", lease_ms: 30_000)
    assert claimed.id == run.id
    authority = worker_opts(claimed, "command-worker")

    assert {:error, :worker_authority_required} =
             Runs.enqueue_command(claimed, "generic", %{tool_name: "write_file"})

    assert {:error, :lease_not_owned} =
             Runs.enqueue_command_worker(claimed, "stale-worker", %{tool_name: "write_file"},
               lease_owner: "other-worker",
               run_attempt: claimed.attempt,
               lease_generation: claimed.lease_generation
             )

    assert {:ok, command} =
             Runs.enqueue_command_worker(
               claimed,
               "worker-command",
               %{run_step_id: step.id, tool_name: "write_file"},
               authority
             )

    assert {:error, :worker_authority_required} =
             Runs.transition_command(command, "running")

    assert {:ok, running_command} =
             Runs.transition_command_worker(command, "running", %{}, authority)

    assert {:error, :worker_authority_required} =
             Runs.request_approval(claimed, %{
               key: "generic-approval",
               action: "workspace_write",
               reason: "Must be worker fenced"
             })

    assert {:ok, approval} =
             Runs.request_approval_worker(
               claimed,
               %{
                 key: "worker-approval",
                 run_command_id: running_command.id,
                 action: "workspace_write",
                 reason: "Human decision remains control-plane callable"
               },
               authority
             )

    assert approval.target_attempt == claimed.attempt
    assert approval.target_generation == claimed.lease_generation
    assert {:ok, approved} = Runs.decide_approval(approval, "approved", %{decided_by: "human"})
    assert approved.status == "approved"
    assert {:error, :stale_approval} = Runs.decide_approval(stale_approval, "denied")
  end

  test "database triggers reject cross-run child identity rewrites", %{
    project: project,
    session: session
  } do
    {:ok, run} = create_run(project, session)
    {:ok, other_run} = create_run(project, session, %{status: "draft"})

    foreign_root =
      Path.join(System.tmp_dir!(), "run-owner-trigger-#{System.unique_integer([:positive])}")

    {:ok, foreign_project} =
      Projects.create_project(%{name: "Foreign run owner", root_path: foreign_root})

    {:ok, foreign_session} =
      Sessions.create_session(%{project_id: foreign_project.id, title: "Foreign run owner"})

    timestamp = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    assert_raise Exqlite.Error, ~r/run_session_project_scope_mismatch/, fn ->
      Repo.query!(
        """
        INSERT INTO runs (id, project_id, session_id, objective, inserted_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?)
        """,
        [
          Ecto.UUID.generate(),
          foreign_project.id,
          session.id,
          "Mismatched direct run",
          timestamp,
          timestamp
        ]
      )
    end

    assert_raise Exqlite.Error, ~r/run_owner_immutable/, fn ->
      Repo.query!("UPDATE runs SET session_id = ? WHERE id = ?", [foreign_session.id, run.id])
    end

    assert_raise Exqlite.Error, ~r/session_project_immutable/, fn ->
      Repo.query!("UPDATE sessions SET project_id = ? WHERE id = ?", [
        foreign_project.id,
        session.id
      ])
    end

    {:ok, parent_step} = Runs.create_step(run, %{key: "parent", kind: "plan", title: "Parent"})

    {:ok, child_step} =
      Runs.create_step(run, %{
        key: "child",
        kind: "execute",
        title: "Child",
        parent_step_id: parent_step.id
      })

    {:ok, other_step} =
      Runs.create_step(other_run, %{key: "other", kind: "plan", title: "Other"})

    {:ok, command} =
      Runs.enqueue_command(run, "scoped-command", %{
        run_step_id: child_step.id,
        tool_name: "write_file"
      })

    {:ok, other_command} =
      Runs.enqueue_command(other_run, "other-scoped-command", %{
        run_step_id: other_step.id,
        tool_name: "read_file"
      })

    {:ok, owner_only_command} =
      Runs.enqueue_command(run, "owner-only-command", %{tool_name: "read_file"})

    {:ok, approval} =
      Runs.request_approval(run, %{
        key: "scoped-approval",
        run_command_id: command.id,
        action: "workspace_write",
        reason: "Scoped"
      })

    {:ok, artifact} =
      Runs.create_artifact(run, %{
        run_step_id: child_step.id,
        kind: "patch",
        name: "scoped.diff",
        uri: "file:///tmp/scoped.diff"
      })

    {:ok, [parent_agent, child_agent]} =
      Runs.create_run_agents(run, [
        %{key: "parent-agent"},
        %{key: "child-agent", parent_key: "parent-agent"}
      ])

    {:ok, [other_agent]} = Runs.create_run_agents(other_run, [%{key: "other-agent"}])

    assert_raise Exqlite.Error, ~r/run_step_parent_scope_mismatch/, fn ->
      Repo.query!("UPDATE run_steps SET parent_step_id = ? WHERE id = ?", [
        other_step.id,
        child_step.id
      ])
    end

    assert_raise Exqlite.Error, ~r/run_step_owner_immutable/, fn ->
      Repo.query!("UPDATE run_steps SET run_id = ? WHERE id = ?", [other_run.id, parent_step.id])
    end

    assert_raise Exqlite.Error, ~r/run_command_step_scope_mismatch/, fn ->
      Repo.query!("UPDATE run_commands SET run_step_id = ? WHERE id = ?", [
        other_step.id,
        command.id
      ])
    end

    assert_raise Exqlite.Error, ~r/run_command_owner_immutable/, fn ->
      Repo.query!("UPDATE run_commands SET run_id = ? WHERE id = ?", [
        other_run.id,
        owner_only_command.id
      ])
    end

    assert_raise Exqlite.Error, ~r/run_approval_command_scope_mismatch/, fn ->
      Repo.query!("UPDATE run_approvals SET run_command_id = ? WHERE id = ?", [
        other_command.id,
        approval.id
      ])
    end

    assert_raise Exqlite.Error, ~r/run_approval_lineage_immutable/, fn ->
      Repo.query!(
        "UPDATE run_approvals SET target_generation = target_generation + 1 WHERE id = ?",
        [approval.id]
      )
    end

    assert_raise Exqlite.Error, ~r/run_artifact_step_scope_mismatch/, fn ->
      Repo.query!("UPDATE run_artifacts SET run_step_id = ? WHERE id = ?", [
        other_step.id,
        artifact.id
      ])
    end

    assert_raise Exqlite.Error, ~r/run_artifact_owner_immutable/, fn ->
      Repo.query!("UPDATE run_artifacts SET run_id = ? WHERE id = ?", [
        other_run.id,
        artifact.id
      ])
    end

    event = Runs.list_events(run) |> List.first()

    assert_raise Exqlite.Error, ~r/run_event_owner_immutable/, fn ->
      Repo.query!("UPDATE run_events SET run_id = ? WHERE id = ?", [other_run.id, event.id])
    end

    assert_raise Exqlite.Error, ~r/run_agent_parent_scope_mismatch/, fn ->
      Repo.query!("UPDATE run_agents SET parent_agent_id = ? WHERE id = ?", [
        other_agent.id,
        child_agent.id
      ])
    end

    assert_raise Exqlite.Error, ~r/run_agent_owner_lineage_immutable/, fn ->
      Repo.query!("UPDATE run_agents SET run_attempt = run_attempt + 1 WHERE id = ?", [
        parent_agent.id
      ])
    end

    {:ok, running} = Runs.claim_next_run("scope-trigger-worker", lease_ms: 30_000)
    assert running.id == run.id

    assert_raise Exqlite.Error, ~r/run_control_target_mismatch/, fn ->
      Repo.query!(
        """
        INSERT INTO run_controls (
          id, run_id, idempotency_key, sequence, target_attempt, target_generation,
          kind, status, payload, requested_by, inserted_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        [
          Ecto.UUID.generate(),
          running.id,
          "stale-direct-control",
          10_000,
          0,
          0,
          "pause",
          "pending",
          "{}",
          "sql-test",
          timestamp,
          timestamp
        ]
      )
    end

    {:ok, immutable_target_control} =
      Runs.enqueue_control(running, "immutable-target-control", %{kind: "steer"})

    assert_raise Exqlite.Error, ~r/run_control_target_immutable/, fn ->
      Repo.query!("UPDATE run_controls SET run_id = ? WHERE id = ?", [
        other_run.id,
        immutable_target_control.id
      ])
    end

    {:ok, [control_agent, other_control_agent]} =
      Runs.create_run_agents(
        running,
        [%{key: "control-agent"}, %{key: "other-control-agent"}],
        run_attempt: running.attempt
      )

    {:ok, control} =
      Runs.enqueue_run_agent_control(control_agent, "scoped-control", %{kind: "pause"})

    assert_raise Exqlite.Error, ~r/run_agent_control_target_immutable/, fn ->
      Repo.query!("UPDATE run_agent_controls SET run_id = ? WHERE id = ?", [
        other_run.id,
        control.id
      ])
    end

    assert_raise Exqlite.Error, ~r/run_agent_control_target_immutable/, fn ->
      Repo.query!("UPDATE run_agent_controls SET run_agent_id = ? WHERE id = ?", [
        other_control_agent.id,
        control.id
      ])
    end

    historical_control_id = Ecto.UUID.generate()

    Repo.query!(
      """
      INSERT INTO run_controls (
        id, run_id, idempotency_key, sequence, target_attempt, target_generation,
        kind, status, payload, result, requested_by, applied_at, inserted_at, updated_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      """,
      [
        historical_control_id,
        running.id,
        "historical-terminal-control",
        10_001,
        running.attempt,
        running.lease_generation,
        "pause",
        "superseded",
        "{}",
        ~s({"reason":"historical"}),
        "sql-test",
        timestamp,
        timestamp,
        timestamp
      ]
    )

    Repo.query!(
      "UPDATE runs SET attempt = attempt + 1, lease_generation = lease_generation + 1 WHERE id = ?",
      [running.id]
    )

    assert_raise Exqlite.Error, ~r/run_control_target_mismatch/, fn ->
      Repo.query!(
        """
        UPDATE run_controls
        SET status = 'pending', result = NULL, applied_at = NULL
        WHERE id = ?
        """,
        [historical_control_id]
      )
    end

    %{rows: [[0]]} =
      Repo.query!("""
      SELECT
        (SELECT COUNT(*) FROM run_steps AS child
         JOIN run_steps AS parent ON parent.id = child.parent_step_id
         WHERE child.parent_step_id IS NOT NULL AND child.run_id != parent.run_id)
        +
        (SELECT COUNT(*) FROM run_commands
         JOIN run_steps ON run_steps.id = run_commands.run_step_id
         WHERE run_commands.run_step_id IS NOT NULL
           AND run_commands.run_id != run_steps.run_id)
        +
        (SELECT COUNT(*) FROM run_approvals
         JOIN run_commands ON run_commands.id = run_approvals.run_command_id
         WHERE run_approvals.run_command_id IS NOT NULL
           AND run_approvals.run_id != run_commands.run_id)
        +
        (SELECT COUNT(*) FROM run_artifacts
         JOIN run_steps ON run_steps.id = run_artifacts.run_step_id
         WHERE run_artifacts.run_step_id IS NOT NULL
           AND run_artifacts.run_id != run_steps.run_id)
        +
        (SELECT COUNT(*) FROM run_agents AS child
         JOIN run_agents AS parent ON parent.id = child.parent_agent_id
         WHERE child.parent_agent_id IS NOT NULL
           AND (child.run_id != parent.run_id OR child.run_attempt != parent.run_attempt))
        +
        (SELECT COUNT(*) FROM run_agent_controls
         JOIN run_agents ON run_agents.id = run_agent_controls.run_agent_id
         WHERE run_agent_controls.run_id != run_agents.run_id)
        +
        (SELECT COUNT(*) FROM run_step_attempts
         JOIN run_steps ON run_steps.id = run_step_attempts.run_step_id
         WHERE run_step_attempts.run_id != run_steps.run_id)
      """)
  end

  test "retry cancels pending approvals from the previous lineage", %{
    project: project,
    session: session
  } do
    {:ok, run} = create_run(project, session)

    {:ok, approval} =
      Runs.request_approval(run, %{
        key: "old-lineage",
        action: "workspace_write",
        reason: "Must not survive a retry"
      })

    assert {:ok, failed} = Runs.transition_run(run, "failed")
    assert {:ok, retried} = Runs.retry_run(failed)
    assert retried.status == "queued"

    assert %{status: "cancelled", decided_by: "system", decision_note: "run_retried"} =
             Runs.get_approval(approval.id)

    assert {:error, {:invalid_transition, "cancelled", "approved"}} =
             Runs.decide_approval(approval, "approved")
  end

  test "run controls are ordered, idempotent, claimed, resolved, and journaled", %{
    project: project,
    session: session
  } do
    {:ok, run} = create_run(project, session)
    :ok = Runs.subscribe(run)

    attrs = %{kind: "steer", payload: %{"guidance" => "Prefer primary sources"}}
    assert {:ok, pending} = Runs.enqueue_control(run, "ui:steer:one", attrs)
    assert pending.sequence == 1
    assert pending.status == "pending"

    assert {:ok, duplicate} = Runs.enqueue_control(run, "ui:steer:one", attrs)
    assert duplicate.id == pending.id

    assert {:error, :idempotency_conflict} =
             Runs.enqueue_control(run, "ui:steer:one", %{
               kind: "cancel",
               payload: %{"unsafe" => true}
             })

    assert_receive {:run_control_enqueued, %{id: control_id}}
    assert control_id == pending.id

    assert {:ok, claimed} = Runs.claim_next_control(run, "dispatcher:test")
    assert claimed.status == "claimed"
    assert claimed.worker_id == "dispatcher:test"
    assert claimed.claimed_at

    assert {:ok, applied} =
             Runs.resolve_control(claimed, "applied", %{"phase" => "research.search"},
               run_id: run.id,
               worker_id: "dispatcher:test",
               kind: "steer"
             )

    assert applied.status == "applied"
    assert applied.result == %{"phase" => "research.search"}
    assert applied.applied_at

    assert {:ok, duplicate_applied} =
             Runs.resolve_control(applied, "applied", %{"phase" => "research.search"},
               run_id: run.id,
               worker_id: "dispatcher:test",
               kind: "steer"
             )

    assert duplicate_applied.id == applied.id

    assert {:error, :control_resolution_conflict} =
             Runs.resolve_control(applied, "applied", %{"phase" => "different"},
               run_id: run.id,
               worker_id: "dispatcher:test",
               kind: "steer"
             )

    assert [^applied] = Runs.list_controls(run)
    assert :none = Runs.claim_next_control(run, "dispatcher:test")

    assert Enum.map(Runs.list_events(run), & &1.type) |> Enum.take(-3) == [
             "run.control_enqueued",
             "run.control_claimed",
             "run.control_applied"
           ]

    assert {:ok, completed} = Runs.transition_run(run, "completed")
    assert {:ok, terminal_retry} = Runs.enqueue_control(completed, "ui:steer:one", attrs)
    assert terminal_retry.id == applied.id
  end

  test "run controls reject secret payloads and terminal targets", %{
    project: project,
    session: session
  } do
    {:ok, run} = create_run(project, session)

    assert {:error, :secret_payload_forbidden} =
             Runs.enqueue_control(run, "secret-steer", %{
               kind: "steer",
               payload: %{"nested" => [%{"access_token" => "do-not-store"}]}
             })

    assert Runs.list_controls(run) == []
    assert {:ok, completed} = Runs.transition_run(run, "completed")

    assert {:error, {:run_not_controllable, "completed"}} =
             Runs.enqueue_control(completed, "late-pause", %{kind: "pause"})
  end

  test "expired control claims can be reclaimed by a new dispatcher incarnation", %{
    project: project,
    session: session
  } do
    {:ok, run} = create_run(project, session)
    {:ok, pending} = Runs.enqueue_control(run, "recover:pause", %{kind: "pause"})
    {:ok, claimed} = Runs.claim_control(pending, "dispatcher:old", claim_ms: 1_000)

    assert claimed.target_attempt == run.attempt
    assert claimed.target_generation == run.lease_generation
    assert claimed.claim_generation == run.lease_generation
    assert DateTime.compare(claimed.claim_expires_at, claimed.claimed_at) == :gt

    assert {:ok, duplicate_claim} =
             Runs.claim_control(claimed, "dispatcher:old", claim_ms: 1_000)

    assert duplicate_claim.id == claimed.id

    future = DateTime.add(claimed.claim_expires_at, 1, :second)

    assert {:error, :control_claim_active} =
             Runs.reclaim_expired_control(claimed, "dispatcher:new")

    assert {:ok, reclaimed} =
             Runs.reclaim_expired_control(claimed, "dispatcher:new", expired_before: future)

    assert reclaimed.id == claimed.id
    assert reclaimed.status == "claimed"
    assert reclaimed.worker_id == "dispatcher:new"

    assert Enum.map(Runs.list_events(run), & &1.type) |> Enum.take(-2) == [
             "run.control_claimed",
             "run.control_reclaimed"
           ]
  end

  test "leased run controls can only be claimed or reclaimed by the parent lease owner", %{
    project: project,
    session: session
  } do
    {:ok, _queued} = create_run(project, session)
    assert {:ok, run} = Runs.claim_next_run("dispatcher:owner", lease_ms: 30_000)
    assert {:ok, pending} = Runs.enqueue_control(run, "owner-bound:pause", %{kind: "pause"})

    assert {:error, :control_worker_not_authorized} =
             Runs.claim_control(pending, "dispatcher:foreign")

    assert {:error, :control_worker_not_authorized} =
             Runs.claim_next_control(run, "dispatcher:foreign")

    assert {:ok, claimed} =
             Runs.claim_control(pending, "dispatcher:owner", claim_ms: 1_000)

    future = DateTime.add(claimed.claim_expires_at, 1, :second)

    assert {:error, :control_worker_not_authorized} =
             Runs.reclaim_expired_control(claimed, "dispatcher:foreign", expired_before: future)

    assert {:ok, reclaimed} =
             Runs.reclaim_expired_control(claimed, "dispatcher:owner", expired_before: future)

    assert reclaimed.worker_id == "dispatcher:owner"
  end

  test "control reconciliation requeues expired claims and fences stale run generations", %{
    project: project,
    session: session
  } do
    {:ok, run} = create_run(project, session)
    {:ok, pending} = Runs.enqueue_control(run, "recover:steer", %{kind: "steer"})
    {:ok, claimed} = Runs.claim_control(pending, "dispatcher:old", claim_ms: 1_000)
    future = DateTime.add(claimed.claim_expires_at, 1, :second)

    assert [{run_id, {:ok, %{reconciled: 1}}}] =
             Runs.reconcile_run_controls(run_id: run.id, expired_before: future)

    assert run_id == run.id

    assert %{status: "pending", worker_id: nil, claim_expires_at: nil} =
             Runs.get_control(claimed.id)

    assert {:ok, reclaimed} = Runs.claim_next_control(run, "dispatcher:new")
    assert reclaimed.id == claimed.id
    assert reclaimed.worker_id == "dispatcher:new"

    {:ok, second_run} = create_run(project, session, %{objective: "stale control target"})
    {:ok, stale} = Runs.enqueue_control(second_run, "stale:pause", %{kind: "pause"})
    assert {:ok, running} = Runs.claim_next_run("dispatcher:claim")
    assert running.id in [run.id, second_run.id]

    # Claim project ordering may select the first run. Advance the exact target directly to
    # model a crash boundary between enqueue and a later run generation claim.
    Repo.update_all(from(candidate in Run, where: candidate.id == ^second_run.id),
      inc: [attempt: 1, lease_generation: 1]
    )

    assert [{second_id, {:ok, %{reconciled: 1}}}] =
             Runs.reconcile_run_controls(run_id: second_run.id)

    assert second_id == second_run.id

    assert %{status: "superseded", result: %{"reason" => "stale_run_generation"}} =
             Runs.get_control(stale.id)
  end

  test "queued cancellation intent recovery terminalizes the run and resolves open controls", %{
    project: project,
    session: session
  } do
    {:ok, run} = create_run(project, session)
    {:ok, pending_cancel} = Runs.enqueue_control(run, "crash:cancel", %{kind: "cancel"})
    {:ok, claimed_cancel} = Runs.claim_control(pending_cancel, "dispatcher:crashed")

    {:ok, steer} =
      Runs.enqueue_control(run, "crash:steer", %{
        kind: "steer",
        payload: %{"guidance" => "too late"}
      })

    {:ok, requested} = Runs.request_cancellation(run)
    assert requested.status == "queued"

    assert [{run_id, {:ok, %{run: cancelled, reconciled: 2}}}] =
             Runs.reconcile_run_controls(run_id: run.id)

    assert run_id == run.id
    assert cancelled.status == "cancelled"
    assert Runs.get_control(claimed_cancel.id).status == "applied"
    assert Runs.get_control(claimed_cancel.id).result["recovered"]
    assert Runs.get_control(steer.id).status == "superseded"
    assert :none = Runs.claim_next_run("dispatcher:other")
  end

  test "terminal reconciliation supersedes pending and expired claimed controls", %{
    project: project,
    session: session
  } do
    {:ok, run} = create_run(project, session)
    {:ok, pending} = Runs.enqueue_control(run, "terminal:pause", %{kind: "pause"})
    {:ok, terminal} = Runs.transition_run(run, "completed")

    assert [{run_id, {:ok, %{reconciled: 1}}}] =
             Runs.reconcile_run_controls(run_id: terminal.id)

    assert run_id == run.id

    assert %{status: "superseded", result: %{"reason" => "run_completed"}} =
             Runs.get_control(pending.id)
  end

  test "cancel reconciliation repairs a crash after terminal status but before control resolution",
       %{
         project: project,
         session: session
       } do
    {:ok, run} = create_run(project, session)
    {:ok, pending} = Runs.enqueue_control(run, "terminal:cancel", %{kind: "cancel"})
    {:ok, claimed} = Runs.claim_control(pending, "dispatcher:crashed")
    {:ok, requested} = Runs.request_cancellation(run)
    {:ok, cancelled} = Runs.transition_run(requested, "cancelled")

    assert Runs.get_control(claimed.id).status == "claimed"

    assert [{run_id, {:ok, %{reconciled: 1}}}] =
             Runs.reconcile_run_controls(run_id: cancelled.id)

    assert run_id == run.id

    assert %{status: "applied", result: %{"recovered" => true}} =
             Runs.get_control(claimed.id)
  end

  test "cancelled run keeps project lease until its worker exits", %{
    project: project,
    session: session
  } do
    {:ok, first} = create_run(project, session, %{priority: "critical"})

    {:ok, second} =
      create_run(project, session, %{objective: "Next project mutation", priority: "low"})

    assert {:ok, claimed} = Runs.claim_next_run("dispatcher-a", lease_ms: 30_000)
    assert claimed.id == first.id

    assert {:ok, requested} = Runs.request_cancellation(claimed)

    assert {:ok, cancelled} =
             Runs.transition_run_worker(
               requested,
               "cancelled",
               %{},
               worker_opts(claimed, "dispatcher-a") ++ [preserve_lease: false]
             )

    assert cancelled.lease_owner == "dispatcher-a"
    assert :none = Runs.claim_next_run("dispatcher-b")
    assert {:error, :run_still_leased} = Runs.retry_run(cancelled)

    assert {:error, :worker_authority_required} =
             Runs.release_lease(cancelled.id, "dispatcher-a")

    assert {:ok, released} =
             Runs.release_lease(
               cancelled.id,
               "dispatcher-a",
               worker_opts(cancelled, "dispatcher-a")
             )

    assert is_nil(released.lease_owner)
    assert {:ok, next} = Runs.claim_next_run("dispatcher-b")
    assert next.id == second.id
  end

  test "cancellation intent rereads current lease lineage and rejects stale terminal snapshots",
       %{
         project: project,
         session: session
       } do
    {:ok, queued_snapshot} = create_run(project, session)
    assert {:ok, claimed} = Runs.claim_next_run("cancel-owner", lease_ms: 30_000)

    assert {:ok, requested} = Runs.request_cancellation(queued_snapshot)
    assert requested.status == "running"
    assert requested.attempt == claimed.attempt
    assert requested.lease_generation == claimed.lease_generation
    assert requested.lease_owner == "cancel-owner"

    cancellation_events =
      Enum.filter(Runs.list_events(requested), &(&1.type == "run.cancellation_requested"))

    assert length(cancellation_events) == 1
    assert {:ok, same_request} = Runs.request_cancellation(queued_snapshot)
    assert same_request.cancellation_requested_at == requested.cancellation_requested_at

    assert length(
             Enum.filter(Runs.list_events(requested), &(&1.type == "run.cancellation_requested"))
           ) ==
             1

    assert {:ok, cancelled} =
             Runs.transition_run_worker(
               requested,
               "cancelled",
               %{},
               worker_opts(requested, "cancel-owner")
             )

    assert {:error, {:invalid_transition, "cancelled", "cancellation_requested"}} =
             Runs.request_cancellation(queued_snapshot)

    assert Runs.get_run!(cancelled.id).cancellation_requested_at ==
             requested.cancellation_requested_at
  end

  test "retry clears an expired lease left by a crashed cancelled worker", %{
    project: project,
    session: session
  } do
    {:ok, run} = create_run(project, session)
    assert {:ok, claimed} = Runs.claim_next_run("crashed-dispatcher", lease_ms: 30_000)
    assert {:ok, requested} = Runs.request_cancellation(claimed)

    assert {:ok, cancelled} =
             Runs.transition_run_worker(
               requested,
               "cancelled",
               %{},
               worker_opts(claimed, "crashed-dispatcher")
             )

    assert {:error, :run_still_leased} = Runs.retry_run(cancelled)

    expired_at = DateTime.add(DateTime.utc_now(), -1, :second) |> DateTime.truncate(:second)

    Repo.update_all(from(r in IexCode.Runs.Run, where: r.id == ^run.id),
      set: [lease_expires_at: expired_at]
    )

    assert {:ok, retried} = Runs.retry_run(cancelled)
    assert retried.status == "queued"
    assert is_nil(retried.lease_owner)
    assert is_nil(retried.lease_expires_at)
  end

  test "retry and next-attempt steps commit atomically", %{project: project, session: session} do
    {:ok, _run} = create_run(project, session, %{max_attempts: 2})
    {:ok, claimed} = Runs.claim_next_run("dispatcher-a")

    {:ok, failed} =
      Runs.finalize_run_worker(
        claimed,
        "failed",
        %{},
        worker_opts(claimed, "dispatcher-a")
      )

    assert {:ok, queued} =
             Runs.retry_run(failed,
               steps: [
                 %{key: "prepare.1", kind: "prepare", title: "Prepare retry", status: "ready"},
                 %{
                   key: "execute.1",
                   kind: "execute",
                   title: "Execute retry",
                   depends_on: ["prepare.1"]
                 }
               ]
             )

    assert queued.status == "queued"
    assert Enum.map(Runs.list_steps(queued), & &1.key) == ["prepare.1", "execute.1"]

    assert Enum.take(Enum.map(Runs.list_events(queued), & &1.type), -3) == [
             "run.retried",
             "run.step_created",
             "run.step_created"
           ]
  end

  test "retry supersedes controls claimed by a prior attempt", %{
    project: project,
    session: session
  } do
    {:ok, _run} = create_run(project, session, %{max_attempts: 2})
    {:ok, claimed_run} = Runs.claim_next_run("dispatcher-a")
    {:ok, pending} = Runs.enqueue_control(claimed_run, "old:pause", %{kind: "pause"})
    assert {:ok, claimed_control} = Runs.claim_control(pending, "dispatcher-a")

    assert {:ok, failed} =
             Runs.finalize_run_worker(
               claimed_run,
               "failed",
               %{},
               worker_opts(claimed_run, "dispatcher-a")
             )

    assert {:ok, _queued} = Runs.retry_run(failed)

    superseded = Runs.get_control(claimed_control.id)
    assert superseded.status == "superseded"
    assert superseded.result == %{"reason" => "run_retried"}
    assert Enum.any?(Runs.list_events(failed), &(&1.type == "run.control_superseded"))
  end

  test "claiming enforces per-project exclusivity, leases, reconciliation, and retry budgets", %{
    project: project,
    session: session
  } do
    {:ok, first} = create_run(project, session, %{priority: "high", max_attempts: 2})
    {:ok, second} = create_run(project, session, %{priority: "low"})

    assert {:ok, claimed} = Runs.claim_next_run("dispatcher-a", lease_ms: 30_000)
    assert claimed.id == first.id
    assert claimed.status == "running"
    assert claimed.lease_owner == "dispatcher-a"
    assert claimed.attempt == 1
    assert :none = Runs.claim_next_run("dispatcher-b", lease_ms: 30_000)

    assert {:error, :worker_authority_required} =
             Runs.renew_lease(claimed.id, "dispatcher-a", 30_000)

    assert {:error, :lease_not_owned} =
             Runs.renew_lease(
               claimed.id,
               "dispatcher-b",
               30_000,
               worker_opts(claimed, "dispatcher-b")
             )

    assert {:ok, renewed} =
             Runs.renew_lease(
               claimed.id,
               "dispatcher-a",
               30_000,
               worker_opts(claimed, "dispatcher-a")
             )

    assert renewed.lease_expires_at

    assert {:ok, first_control} =
             Runs.enqueue_control(claimed, "orphan:pause", %{kind: "pause"})

    assert {:ok, claimed_control} = Runs.claim_control(first_control, "dispatcher-a")

    assert {:ok, pending_control} =
             Runs.enqueue_control(claimed, "orphan:steer", %{
               kind: "steer",
               payload: %{"guidance" => "still pending"}
             })

    expired = DateTime.add(DateTime.utc_now(), -1, :second) |> DateTime.truncate(:second)

    Repo.update_all(from(r in IexCode.Runs.Run, where: r.id == ^claimed.id),
      set: [lease_expires_at: expired]
    )

    assert [%{id: id, status: "interrupted"}] = Runs.reconcile_orphaned_runs()
    assert id == claimed.id
    assert Runs.get_control(claimed_control.id).status == "superseded"
    assert Runs.get_control(pending_control.id).status == "superseded"
    assert Runs.get_control(pending_control.id).result == %{"reason" => "run_interrupted"}
    assert {:ok, retried} = Runs.retry_run(claimed.id)
    assert retried.status == "queued"
    assert is_nil(retried.lease_owner)

    assert {:ok, reclaimed} = Runs.claim_next_run("dispatcher-b")
    assert reclaimed.id == first.id
    assert reclaimed.attempt == 2

    assert {:ok, failed} =
             Runs.finalize_run_worker(
               reclaimed,
               "failed",
               %{},
               worker_opts(reclaimed, "dispatcher-b")
             )

    assert {:error, :attempts_exhausted} = Runs.retry_run(failed)

    assert {:ok, next_project_run} = Runs.claim_next_run("dispatcher-c")
    assert next_project_run.id == second.id
  end

  test "worker mutations are fenced from a newer retry generation", %{
    project: project,
    session: session
  } do
    {:ok, _run} = create_run(project, session, %{max_attempts: 3})
    assert {:ok, first} = Runs.claim_next_run("stable-worker", lease_ms: 30_000)

    expired = DateTime.add(DateTime.utc_now(), -1, :second) |> DateTime.truncate(:second)

    Repo.update_all(from(run in Run, where: run.id == ^first.id),
      set: [lease_expires_at: expired]
    )

    assert [%{id: first_id}] = Runs.reconcile_orphaned_runs()
    assert first_id == first.id
    assert {:ok, _queued} = Runs.retry_run(first.id)
    assert {:ok, second} = Runs.claim_next_run("stable-worker", lease_ms: 30_000)
    assert second.attempt == 2
    assert second.lease_generation == 2

    stale = [
      lease_owner: "stable-worker",
      run_attempt: first.attempt,
      lease_generation: first.lease_generation
    ]

    assert {:error, :lease_not_owned} =
             Runs.renew_lease(first.id, "stable-worker", 30_000, stale)

    assert {:error, :lease_not_owned} =
             Runs.record_progress(first.id, 70, "stale", "worker", stale)

    assert {:error, :lease_not_owned} =
             Runs.record_usage(first.id, %{input_tokens: 10}, "worker", stale)

    assert {:error, :lease_not_owned} =
             Runs.transition_run_worker(first.id, "completed", %{}, stale)

    assert {:error, :lease_not_owned} = Runs.release_lease(first.id, "stable-worker", stale)

    assert {:error, :worker_authority_required} =
             Runs.renew_lease(first.id, "stable-worker", 30_000)

    assert {:error, :worker_authority_required} =
             Runs.release_lease(first.id, "stable-worker")

    persisted = Runs.get_run!(first.id)
    assert persisted.status == "running"
    assert persisted.attempt == second.attempt
    assert persisted.lease_generation == second.lease_generation
    assert persisted.input_tokens == 0
    assert persisted.progress == 0
  end

  test "generic worker terminal transition atomically terminalizes the current graph", %{
    project: project,
    session: session
  } do
    attrs = %{
      project_id: project.id,
      session_id: session.id,
      objective: "Finalize the graph through the compatibility API"
    }

    assert {:ok, _queued} =
             Runs.create_run_with_steps(attrs, [
               %{key: "prepare", kind: "prepare", title: "Prepare", status: "ready"},
               %{
                 key: "execute",
                 kind: "execute",
                 title: "Execute",
                 status: "pending",
                 depends_on: ["prepare"]
               }
             ])

    assert {:ok, claimed} = Runs.claim_next_run("compat-worker", lease_ms: 30_000)

    assert {:ok, completed} =
             Runs.transition_run_worker(
               claimed,
               "completed",
               %{result: %{"outcome" => "done"}},
               worker_opts(claimed, "compat-worker") ++
                 [preserve_lease: false, terminal_lease_ms: 1]
             )

    assert completed.status == "completed"
    assert completed.lease_owner == "compat-worker"
    assert DateTime.diff(completed.lease_expires_at, completed.completed_at, :second) == 30

    assert Enum.map(Runs.list_steps(completed), &{&1.kind, &1.status}) == [
             {"prepare", "skipped"},
             {"execute", "completed"}
           ]

    assert Enum.any?(Runs.list_events(completed), &(&1.type == "run.step_status_changed"))

    assert {:ok, released} =
             Runs.release_lease(
               completed.id,
               "compat-worker",
               worker_opts(completed, "compat-worker")
             )

    assert is_nil(released.lease_owner)
  end

  test "generic unleased terminal transition atomically terminalizes the current graph", %{
    project: project,
    session: session
  } do
    attrs = %{
      project_id: project.id,
      session_id: session.id,
      objective: "Cancel an unleased graph"
    }

    assert {:ok, queued} =
             Runs.create_run_with_steps(attrs, [
               %{key: "prepare", kind: "prepare", title: "Prepare", status: "ready"},
               %{
                 key: "execute",
                 kind: "execute",
                 title: "Execute",
                 status: "pending",
                 depends_on: ["prepare"]
               }
             ])

    assert {:ok, cancelled} = Runs.transition_run(queued, "cancelled")
    assert cancelled.status == "cancelled"
    assert Enum.all?(Runs.list_steps(cancelled), &(&1.status == "cancelled"))
  end

  test "leased runs reject every unscoped worker mutation", %{
    project: project,
    session: session
  } do
    {:ok, queued} = create_run(project, session, %{token_budget: 100})

    {:ok, step} =
      Runs.create_step(queued, %{
        key: "scoped-step",
        kind: "execute",
        title: "Scoped transition"
      })

    {:ok, claimed} = Runs.claim_next_run("scoped-worker", lease_ms: 30_000)

    assert {:error, :worker_authority_required} =
             Runs.heartbeat_run(claimed, %{progress: 10})

    assert {:error, :worker_authority_required} =
             Runs.record_progress(claimed, 20, "unfenced", "worker")

    assert {:error, :worker_authority_required} =
             Runs.record_usage(claimed, %{input_tokens: 5}, "worker")

    assert {:error, :worker_authority_required} =
             Runs.transition_run(claimed, "failed")

    assert {:error, :worker_authority_required} =
             Runs.transition_step(step, "running")

    assert {:error, :worker_authority_required} =
             Runs.create_step(claimed, %{
               key: "unfenced-step",
               kind: "execute",
               title: "Must not be created"
             })

    unchanged = Runs.get_run!(claimed.id)
    assert unchanged.progress == claimed.progress
    assert unchanged.input_tokens == claimed.input_tokens
    assert unchanged.lease_owner == "scoped-worker"

    assert Enum.map(Runs.list_events(claimed), & &1.type) == [
             "run.created",
             "run.step_created",
             "run.claimed"
           ]
  end

  test "expired same-lineage worker cannot terminalize steps before its parent", %{
    project: project,
    session: session
  } do
    attrs = %{
      project_id: project.id,
      session_id: session.id,
      objective: "Fence atomic worker finalization"
    }

    assert {:ok, _queued} =
             Runs.create_run_with_steps(attrs, [
               %{key: "prepare", kind: "prepare", title: "Prepare", status: "ready"},
               %{
                 key: "execute",
                 kind: "execute",
                 title: "Execute",
                 status: "pending",
                 depends_on: ["prepare"]
               }
             ])

    assert {:ok, claimed} = Runs.claim_next_run("expired-worker", lease_ms: 30_000)
    [execute, prepare] = Runs.list_steps(claimed) |> Enum.sort_by(& &1.kind)
    authority = worker_opts(claimed, "expired-worker")

    assert {:ok, running_prepare} =
             Runs.transition_step_worker(prepare, "running", %{}, authority)

    assert {:ok, _completed_prepare} =
             Runs.transition_step_worker(running_prepare, "completed", %{}, authority)

    assert {:ok, running_execute} =
             Runs.transition_step_worker(execute, "running", %{}, authority)

    expired = DateTime.add(DateTime.utc_now(), -1, :second) |> DateTime.truncate(:second)

    Repo.update_all(from(run in Run, where: run.id == ^claimed.id),
      set: [lease_expires_at: expired]
    )

    assert {:error, :lease_not_owned} =
             Runs.finalize_run_worker(claimed, "completed", %{},
               lease_owner: "expired-worker",
               run_attempt: claimed.attempt,
               lease_generation: claimed.lease_generation
             )

    assert Runs.get_run!(claimed.id).status == "running"
    assert Runs.get_step(running_execute.id).status == "running"
    assert Runs.get_step(running_prepare.id).status == "completed"
  end

  test "expired DAG worker cannot terminalize graph before its parent", %{
    project: project,
    session: session
  } do
    attrs = %{
      project_id: project.id,
      session_id: session.id,
      objective: "Fence atomic DAG finalization",
      kind: "analysis",
      mode: "workflow",
      execution_engine: "dag_v1"
    }

    assert {:ok, _queued} = Runs.create_run_with_steps(attrs, dag_steps())
    assert {:ok, claimed} = Runs.claim_next_run("expired-dag-worker", lease_ms: 30_000)
    [inventory | _] = Runs.list_steps(claimed)

    assert {:ok, running_inventory} =
             Runs.transition_step_worker(
               inventory,
               "running",
               %{},
               worker_opts(claimed, "expired-dag-worker")
             )

    expired = DateTime.add(DateTime.utc_now(), -1, :second) |> DateTime.truncate(:second)

    Repo.update_all(from(run in Run, where: run.id == ^claimed.id),
      set: [lease_expires_at: expired]
    )

    assert {:error, :lease_not_owned} =
             Runs.finalize_run_worker(claimed, "interrupted", %{},
               lease_owner: "expired-dag-worker",
               run_attempt: claimed.attempt,
               lease_generation: claimed.lease_generation
             )

    assert Runs.get_run!(claimed.id).status == "running"
    assert Runs.get_step(running_inventory.id).status == "running"
  end

  test "expired worker cannot prepare legacy steps", %{project: project, session: session} do
    attrs = %{
      project_id: project.id,
      session_id: session.id,
      objective: "Fence preparation"
    }

    assert {:ok, _queued} =
             Runs.create_run_with_steps(attrs, [
               %{key: "prepare", kind: "prepare", title: "Prepare", status: "ready"},
               %{
                 key: "execute",
                 kind: "execute",
                 title: "Execute",
                 status: "pending",
                 depends_on: ["prepare"]
               }
             ])

    assert {:ok, claimed} = Runs.claim_next_run("prepare-worker", lease_ms: 30_000)
    expired = DateTime.add(DateTime.utc_now(), -1, :second) |> DateTime.truncate(:second)

    Repo.update_all(from(run in Run, where: run.id == ^claimed.id),
      set: [lease_expires_at: expired]
    )

    assert {:error, :lease_not_owned} =
             Runs.prepare_run_worker(claimed,
               lease_owner: "prepare-worker",
               run_attempt: claimed.attempt,
               lease_generation: claimed.lease_generation
             )

    assert Enum.map(Runs.list_steps(claimed), & &1.status) == ["ready", "pending"]
  end

  test "queued cancellation and orphan interruption atomically terminalize legacy graphs", %{
    project: project,
    session: session
  } do
    steps = [
      %{key: "prepare", kind: "prepare", title: "Prepare", status: "ready"},
      %{
        key: "execute",
        kind: "execute",
        title: "Execute",
        status: "pending",
        depends_on: ["prepare"]
      }
    ]

    attrs = %{
      project_id: project.id,
      session_id: session.id,
      objective: "Recover queued cancellation"
    }

    assert {:ok, queued} = Runs.create_run_with_steps(attrs, steps)
    assert {:ok, _requested} = Runs.request_cancellation(queued)
    assert [{run_id, {:ok, %{}}}] = Runs.reconcile_run_controls(run_id: queued.id)
    assert run_id == queued.id
    assert Runs.get_run!(queued.id).status == "cancelled"
    assert Enum.all?(Runs.list_steps(queued), &(&1.status == "cancelled"))

    assert {:ok, _queued_orphan} =
             Runs.create_run_with_steps(%{attrs | objective: "Recover orphan graph"}, steps)

    assert {:ok, orphan} = Runs.claim_next_run("orphan-worker", lease_ms: 30_000)

    assert {:ok, execute} =
             Runs.prepare_run_worker(orphan,
               lease_owner: "orphan-worker",
               run_attempt: orphan.attempt,
               lease_generation: orphan.lease_generation
             )

    expired = DateTime.add(DateTime.utc_now(), -1, :second) |> DateTime.truncate(:second)

    Repo.update_all(from(run in Run, where: run.id == ^orphan.id),
      set: [lease_expires_at: expired]
    )

    assert [%{id: orphan_id, status: "interrupted"}] = Runs.reconcile_orphaned_runs()
    assert orphan_id == orphan.id
    assert Runs.get_step(execute.id).status == "interrupted"
  end

  test "legacy pause receipt cannot mutate parent or step after worker lease expiry", %{
    project: project,
    session: session
  } do
    attrs = %{
      project_id: project.id,
      session_id: session.id,
      objective: "Fence pause receipt"
    }

    assert {:ok, _queued} =
             Runs.create_run_with_steps(attrs, [
               %{key: "prepare", kind: "prepare", title: "Prepare", status: "ready"},
               %{
                 key: "execute",
                 kind: "execute",
                 title: "Execute",
                 status: "pending",
                 depends_on: ["prepare"]
               }
             ])

    assert {:ok, run} = Runs.claim_next_run("pause-worker", lease_ms: 30_000)

    assert {:ok, execute} =
             Runs.prepare_run_worker(run,
               lease_owner: "pause-worker",
               run_attempt: run.attempt,
               lease_generation: run.lease_generation
             )

    assert {:ok, pending} = Runs.enqueue_control(run, "pause:fenced", %{kind: "pause"})
    assert {:ok, claimed} = Runs.claim_control(pending, "pause-worker")
    expired = DateTime.add(DateTime.utc_now(), -1, :second) |> DateTime.truncate(:second)

    Repo.update_all(from(current in Run, where: current.id == ^run.id),
      set: [lease_expires_at: expired]
    )

    assert {:error, :lease_not_owned} =
             Runs.apply_claimed_legacy_control(claimed, "paused",
               lease_owner: "pause-worker",
               run_attempt: run.attempt,
               lease_generation: run.lease_generation
             )

    assert Runs.get_run!(run.id).status == "running"
    assert Runs.get_step(execute.id).status == "running"
    assert Runs.get_control(claimed.id).status == "claimed"
  end

  test "orphaned parent reconciliation releases live fleet identities for retry", %{
    project: project,
    session: session
  } do
    {:ok, _run} = create_run(project, session, %{max_attempts: 3})
    assert {:ok, claimed_run} = Runs.claim_next_run("dead-dispatcher", lease_ms: 30_000)
    assert {:ok, [agent]} = Runs.create_run_agents(claimed_run, [%{key: "planner"}])
    assert {:ok, claimed_agent} = Runs.claim_run_agent(agent, "dead-fleet", 30_000)

    expired = DateTime.add(DateTime.utc_now(), -1, :second) |> DateTime.truncate(:second)

    Repo.update_all(from(run in Run, where: run.id == ^claimed_run.id),
      set: [lease_expires_at: expired]
    )

    assert [%{id: run_id, status: "interrupted"}] = Runs.reconcile_orphaned_runs()
    assert run_id == claimed_run.id
    assert Runs.get_run_agent(claimed_agent.id).status == "interrupted"

    assert {:ok, _queued} = Runs.retry_run(claimed_run.id)
    assert {:ok, retried} = Runs.claim_next_run("next-dispatcher", lease_ms: 30_000)
    assert retried.attempt == 2

    assert {:ok, [next_agent]} = Runs.ensure_run_agents(retried, [%{key: "planner"}])
    assert next_agent.run_attempt == 2
    refute next_agent.id == claimed_agent.id
  end

  test "terminalizing a retry preserves historical run-agent outcomes", %{
    project: project,
    session: session
  } do
    {:ok, _run} = create_run(project, session, %{max_attempts: 3})
    {:ok, first} = Runs.claim_next_run("worker-one", lease_ms: 30_000)
    {:ok, [first_agent]} = Runs.create_run_agents(first, [%{key: "planner"}])
    {:ok, first_agent} = Runs.claim_run_agent(first_agent, "fleet-one", 30_000)

    expired = DateTime.add(DateTime.utc_now(), -1, :second) |> DateTime.truncate(:second)

    Repo.update_all(from(run in Run, where: run.id == ^first.id),
      set: [lease_expires_at: expired]
    )

    assert [%{id: run_id}] = Runs.reconcile_orphaned_runs()
    assert run_id == first.id
    assert Runs.get_run_agent(first_agent.id).status == "interrupted"

    {:ok, _queued} = Runs.retry_run(first)
    {:ok, second} = Runs.claim_next_run("worker-two", lease_ms: 30_000)
    {:ok, [second_agent]} = Runs.ensure_run_agents(second, [%{key: "planner"}])
    {:ok, _second_agent} = Runs.claim_run_agent(second_agent, "fleet-two", 30_000)

    assert {:ok, _failed} =
             Runs.finalize_run_worker(second, "failed", %{},
               lease_owner: "worker-two",
               run_attempt: second.attempt,
               lease_generation: second.lease_generation
             )

    assert Runs.get_run_agent(first_agent.id).status == "interrupted"
    assert Runs.get_run_agent(second_agent.id).status == "failed"
  end
end
