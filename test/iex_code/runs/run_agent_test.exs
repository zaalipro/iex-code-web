defmodule IexCode.Runs.RunAgentTest do
  use IexCode.DataCase, async: false

  alias IexCode.{Projects, Runs, Sessions}
  alias IexCode.Runs.{RunAgent, RunAgentControl}

  setup do
    root =
      Path.join(System.tmp_dir!(), "iex-code-agent-fleet-#{System.unique_integer([:positive])}")

    {:ok, project} = Projects.create_project(%{name: "Agent Fleet", root_path: root})
    {:ok, session} = Sessions.create_session(%{project_id: project.id, title: "Fleet"})

    {:ok, _queued} =
      Runs.create_run(%{
        project_id: project.id,
        session_id: session.id,
        objective: "Run a durable dynamic fleet"
      })

    owner = "run-agent-test:#{System.unique_integer([:positive])}"
    {:ok, run} = Runs.claim_next_run(owner, lease_ms: 300_000)
    %{project: project, session: session, run: run}
  end

  defp transition_parent(run, status, attrs \\ %{}) do
    Runs.transition_run_worker(run, status, attrs,
      lease_owner: run.lease_owner,
      run_attempt: run.attempt,
      lease_generation: run.lease_generation
    )
  end

  test "creates a bounded ordered manifest with parent scope and durable events", %{run: run} do
    :ok = Runs.subscribe(run)

    assert {:ok, [planner, explorer]} =
             Runs.create_run_agents(run, [
               %{key: "planner", role: "planner", adapter: "otp.planner"},
               %{
                 key: "explorer-01",
                 role: "explorer",
                 adapter: "otp.explorer",
                 parent_key: "planner",
                 capabilities: ["workspace.read"]
               }
             ])

    assert planner.display_name == "Planner"
    assert explorer.parent_agent_id == planner.id
    assert explorer.position == 1
    assert [^planner, ^explorer] = Runs.list_run_agents(run)
    assert Runs.get_run_agent(run.id, explorer.id).id == explorer.id
    assert Runs.get_run_agent_by_key(run, "planner").id == planner.id
    planner_id = planner.id
    assert_receive {:run_agent_created, %{id: ^planner_id}}

    assert Enum.map(Runs.list_events(run), & &1.type) |> Enum.take(-2) == [
             "run.agent_created",
             "run.agent_created"
           ]
  end

  test "manifest is atomic, bounded, idempotently ensured, and rejects cross-run parents", %{
    project: project,
    session: session,
    run: run
  } do
    assert {:error, :duplicate_agent_key} =
             Runs.create_run_agents(run, [%{key: "dup"}, %{key: "dup"}])

    assert [] = Runs.list_run_agents(run)

    assert {:ok, [first]} = Runs.ensure_run_agents(run, [%{key: "explorer-01"}])
    assert {:ok, [same]} = Runs.ensure_run_agents(run, [%{key: "explorer-01"}])
    assert same.id == first.id

    oversized = for n <- 1..65, do: %{key: "worker-#{n}"}
    assert {:error, {:agent_manifest_too_large, 64}} = Runs.create_run_agents(run, oversized)

    {:ok, other_run} =
      Runs.create_run(%{
        project_id: project.id,
        session_id: session.id,
        objective: "Other run"
      })

    assert {:error, :parent_agent_scope_mismatch} =
             Runs.create_run_agents(other_run, [%{key: "child", parent_agent_id: first.id}])
  end

  test "claims and transitions with generation fencing and rejects stale workers", %{run: run} do
    {:ok, [agent]} = Runs.create_run_agents(run, [%{key: "coder"}])
    assert {:ok, claimed} = Runs.claim_run_agent(agent, "fleet:test", 60_000)
    assert claimed.status == "starting"
    assert claimed.attempt == 1
    assert claimed.lease_generation == 1

    assert {:error, :lease_lost} =
             Runs.transition_run_agent(claimed, "idle", %{},
               lease_owner: "fleet:other",
               lease_generation: 1
             )

    assert {:ok, idle} =
             Runs.transition_run_agent(claimed, "idle", %{current_task: "Awaiting work"},
               lease_owner: "fleet:test",
               lease_generation: 1
             )

    assert {:ok, heartbeat} =
             Runs.heartbeat_run_agent(idle, "fleet:test", 1, 60_000, %{
               progress: 12,
               current_task: "Scanning"
             })

    assert heartbeat.progress == 12

    assert {:ok, interrupted} =
             Runs.release_run_agent_lease(heartbeat, "fleet:test", 1)

    assert interrupted.status == "interrupted"
    assert is_nil(interrupted.lease_owner)
    assert {:error, :lease_lost} = Runs.heartbeat_run_agent(interrupted, "fleet:test", 1)

    assert {:ok, reclaimed} = Runs.claim_run_agent(interrupted, "fleet:new", 60_000)
    assert reclaimed.lease_generation == 2
    assert reclaimed.restart_count == 1
  end

  test "lifecycle transitions reject immutable identity, topology, capability, and lease attrs",
       %{
         run: run
       } do
    {:ok, [agent]} =
      Runs.create_run_agents(run, [
        %{key: "immutable", role: "coder", adapter: "otp.coder", capabilities: ["write"]}
      ])

    {:ok, claimed} = Runs.claim_run_agent(agent, "fleet:immutable", 60_000)

    assert {:error, {:immutable_agent_fields, rejected}} =
             Runs.transition_run_agent(
               claimed,
               "idle",
               %{
                 key: "hijacked",
                 role: "planner",
                 adapter: "arbitrary.module",
                 parent_agent_id: Ecto.UUID.generate(),
                 run_attempt: 99,
                 capabilities: ["admin"],
                 config: %{"unsafe" => true},
                 input_tokens: 9_999,
                 request_count: 9_999,
                 lease_owner: "attacker",
                 lease_generation: 999
               },
               lease_owner: "fleet:immutable",
               lease_generation: claimed.lease_generation
             )

    assert :key in rejected
    assert :parent_agent_id in rejected
    assert :capabilities in rejected
    assert :config in rejected
    assert :lease_owner in rejected

    unchanged = Runs.get_run_agent(claimed.id)
    assert unchanged.status == "starting"
    assert unchanged.key == "immutable"
    assert unchanged.role == "coder"
    assert unchanged.adapter == "otp.coder"
    assert unchanged.capabilities == ["write"]
    assert unchanged.config == %{}
    assert unchanged.input_tokens == 0
    assert unchanged.request_count == 0
    assert unchanged.lease_generation == claimed.lease_generation

    assert {:ok, _agent} =
             Runs.assert_run_agent_lease(unchanged, "fleet:immutable", claimed.lease_generation)
  end

  test "fleet bearer credentials are hashed, redacted, and absent from events and PubSub", %{
    run: run
  } do
    bearer = "fleet-raw-sentinel-#{System.unique_integer([:positive])}"
    {:ok, [agent]} = Runs.create_run_agents(run, [%{key: "secure"}])
    :ok = Runs.subscribe(run)
    {:ok, claimed} = Runs.claim_run_agent(agent, bearer, 60_000)

    persisted_hash =
      Repo.one!(from(row in RunAgent, where: row.id == ^claimed.id, select: row.lease_owner))

    assert byte_size(persisted_hash) == 64
    refute persisted_hash == bearer
    refute inspect(claimed) =~ bearer
    refute inspect(claimed) =~ persisted_hash
    assert {:ok, _agent} = Runs.assert_run_agent_lease(claimed, bearer, claimed.lease_generation)

    assert {:error, :lease_lost} =
             Runs.assert_run_agent_lease(claimed, bearer <> "-wrong", claimed.lease_generation)

    assert_receive {:run_agent_updated, broadcast_agent}
    refute inspect(broadcast_agent) =~ bearer

    refute inspect(Runs.list_events(run.id)) =~ bearer

    {:ok, control} =
      Runs.enqueue_run_agent_control(claimed, "secure-control", %{kind: "pause", payload: %{}})

    {:ok, control} =
      Runs.claim_next_run_agent_control(control.run_agent_id, bearer, claimed.lease_generation)

    persisted_claim_hash =
      Repo.one!(
        from(row in RunAgentControl, where: row.id == ^control.id, select: row.claim_owner)
      )

    assert byte_size(persisted_claim_hash) == 64
    refute persisted_claim_hash == bearer
    refute inspect(control) =~ bearer
    refute inspect(control) =~ persisted_claim_hash
  end

  test "concurrent claims yield one fenced owner", %{run: run} do
    {:ok, [agent]} = Runs.create_run_agents(run, [%{key: "explorer"}])

    results =
      1..8
      |> Task.async_stream(
        fn n -> Runs.claim_run_agent(agent.id, "worker:#{n}", 60_000) end,
        max_concurrency: 8,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, %RunAgent{}}, &1)) == 1
    assert Runs.get_run_agent(agent.id).lease_generation == 1
  end

  test "targeted controls are ordered, idempotent, and fenced through resolution", %{run: run} do
    {:ok, [agent]} = Runs.create_run_agents(run, [%{key: "verifier"}])
    {:ok, agent} = Runs.claim_run_agent(agent, "fleet:test", 60_000)

    {:ok, agent} =
      Runs.transition_run_agent(agent, "idle", %{},
        lease_owner: "fleet:test",
        lease_generation: agent.lease_generation
      )

    assert {:ok, pending} =
             Runs.enqueue_run_agent_control(agent, "ui:pause:1", %{
               kind: "pause",
               payload: %{"reason" => "Inspect output"}
             })

    assert pending.sequence == 1
    assert pending.target_generation == agent.lease_generation

    assert {:ok, duplicate} =
             Runs.enqueue_run_agent_control(agent, "ui:pause:1", %{
               kind: "pause",
               payload: %{"reason" => "Inspect output"}
             })

    assert duplicate.id == pending.id

    assert {:error, :idempotency_conflict} =
             Runs.enqueue_run_agent_control(agent, "ui:pause:1", %{
               kind: "cancel",
               payload: %{}
             })

    assert {:ok, second_pending} =
             Runs.enqueue_run_agent_control(agent, "ui:steer:2", %{
               kind: "steer",
               payload: %{"guidance" => "Focus on invariants"}
             })

    assert {:error, :lease_lost} =
             Runs.claim_next_run_agent_control(agent, "fleet:test", agent.lease_generation + 1)

    assert {:ok, claimed} =
             Runs.claim_next_run_agent_control(agent, "fleet:test", agent.lease_generation)

    assert :none =
             Runs.claim_next_run_agent_control(agent, "fleet:test", agent.lease_generation)

    assert {:error, :control_claim_lost} =
             Runs.resolve_run_agent_control(
               claimed,
               "applied",
               %{"status" => "paused"},
               "fleet:other",
               agent.lease_generation
             )

    assert {:ok, applied} =
             Runs.resolve_run_agent_control(
               claimed,
               "applied",
               %{"status" => "paused"},
               "fleet:test",
               agent.lease_generation
             )

    assert applied.status == "applied"

    assert {:ok, claimed_second} =
             Runs.claim_next_run_agent_control(agent, "fleet:test", agent.lease_generation)

    assert claimed_second.id == second_pending.id

    assert [^applied, %RunAgentControl{status: "claimed"}] =
             Runs.list_run_agent_controls(agent)
  end

  test "usage is fenced, updates run totals, records latency, and preserves token budget", %{
    project: project,
    session: session,
    run: run
  } do
    {:ok, run} = transition_parent(run, "paused")
    {:ok, run} = transition_parent(run, "running", %{token_budget: 10})
    {:ok, [agent]} = Runs.create_run_agents(run, [%{key: "planner"}])
    {:ok, agent} = Runs.claim_run_agent(agent, "fleet:test", 60_000)

    assert {:error, :lease_lost} =
             Runs.record_run_agent_usage(agent, %{input_tokens: 2}, "planner.llm",
               lease_owner: "wrong",
               lease_generation: agent.lease_generation
             )

    assert {:ok, updated} =
             Runs.record_run_agent_usage(
               agent,
               %{input_tokens: 4, output_tokens: 2, cost_cents: 3, latency_ms: 90},
               "planner.llm",
               lease_owner: "fleet:test",
               lease_generation: agent.lease_generation
             )

    assert updated.request_count == 1
    assert updated.last_latency_ms == 90
    assert updated.average_latency_ms == 90
    assert %{input_tokens: 4, output_tokens: 2, cost_cents: 3} = Runs.get_run!(run.id)

    assert {:error, {:token_budget_exhausted, failed_run}} =
             Runs.record_run_agent_usage(
               updated,
               %{input_tokens: 5},
               "planner.llm",
               lease_owner: "fleet:test",
               lease_generation: agent.lease_generation
             )

    assert failed_run.status == "failed"
    assert failed_run.lease_owner == run.lease_owner

    assert {:ok, _queued} =
             Runs.create_run(%{
               project_id: project.id,
               session_id: session.id,
               objective: "Queued behind token-exhausted owner"
             })

    assert :none = Runs.claim_next_run("other-token-dispatcher")
  end

  test "rejects recursively secret-shaped durable payloads", %{run: run} do
    assert {:error, :secret_payload_forbidden} =
             Runs.create_run_agents(run, [
               %{key: "unsafe", config: %{"nested" => %{"api_key" => "never-store"}}}
             ])

    {:ok, [agent]} = Runs.create_run_agents(run, [%{key: "safe"}])

    assert {:error, :secret_payload_forbidden} =
             Runs.enqueue_run_agent_control(agent, "unsafe-control", %{
               kind: "steer",
               payload: %{"access_token" => "never-store"}
             })
  end

  test "reconciliation and terminalization clear leases and open controls", %{run: run} do
    {:ok, [first, second]} =
      Runs.create_run_agents(run, [%{key: "first"}, %{key: "second"}])

    {:ok, first} = Runs.claim_run_agent(first, "fleet:first", 60_000)
    {:ok, second} = Runs.claim_run_agent(second, "fleet:second", 60_000)

    Repo.update_all(
      from(agent in RunAgent, where: agent.id == ^first.id),
      set: [lease_expires_at: DateTime.add(DateTime.utc_now(), -1, :second)]
    )

    assert [%{id: first_id, status: "interrupted"}] =
             Runs.reconcile_orphaned_run_agents(run_id: run.id)

    assert first_id == first.id

    assert {:ok, _control} =
             Runs.enqueue_run_agent_control(second, "stop:1", %{kind: "cancel", payload: %{}})

    assert {:ok, terminalized} =
             Runs.terminalize_run_agents(run, "cancelled", %{},
               lease_owner: run.lease_owner,
               run_attempt: run.attempt,
               lease_generation: run.lease_generation
             )

    assert Enum.any?(terminalized, &(&1.id == second.id and &1.status == "cancelled"))
    assert [%RunAgentControl{status: "superseded"}] = Runs.list_run_agent_controls(second)
  end

  test "fresh heartbeats win over future-cutoff reconciliation and stale controls recover", %{
    run: run
  } do
    first_owner = "fleet:first-generation"
    second_owner = "fleet:replacement-generation"
    {:ok, [agent]} = Runs.create_run_agents(run, [%{key: "recoverable"}])
    {:ok, agent} = Runs.claim_run_agent(agent, first_owner, 60_000)

    assert [] =
             Runs.reconcile_orphaned_run_agents(
               run_id: run.id,
               expired_before: DateTime.add(DateTime.utc_now(), 86_400, :second)
             )

    assert {:ok, control} =
             Runs.enqueue_run_agent_control(agent, "recover:pause", %{kind: "pause", payload: %{}})

    assert {:ok, claimed_control} =
             Runs.claim_next_run_agent_control(agent, first_owner, agent.lease_generation)

    Repo.update_all(
      from(row in RunAgentControl, where: row.id == ^claimed_control.id),
      set: [claimed_at: DateTime.add(DateTime.utc_now(), -60, :second)]
    )

    Repo.update_all(
      from(row in RunAgent, where: row.id == ^agent.id),
      set: [lease_expires_at: DateTime.add(DateTime.utc_now(), -1, :second)]
    )

    assert [%RunAgent{status: "interrupted"}] =
             Runs.reconcile_orphaned_run_agents(run_id: run.id)

    assert {:ok, replacement} = Runs.claim_run_agent(agent.id, second_owner, 60_000)
    assert replacement.lease_generation == 2

    assert {:ok, recovered_control} =
             Runs.claim_next_run_agent_control(
               replacement,
               second_owner,
               replacement.lease_generation,
               claim_timeout_ms: 30_000
             )

    assert recovered_control.id == control.id
    assert recovered_control.target_generation == replacement.lease_generation
    assert recovered_control.claim_generation == replacement.lease_generation
  end

  test "heartbeat and reconciliation race cannot interrupt a fresh fenced lease", %{run: run} do
    owner = "fleet:heartbeat-race"
    {:ok, [agent]} = Runs.create_run_agents(run, [%{key: "heartbeat-race"}])
    {:ok, agent} = Runs.claim_run_agent(agent, owner, 60_000)

    results =
      [
        fn -> Runs.heartbeat_run_agent(agent, owner, agent.lease_generation, 60_000) end,
        fn -> Runs.reconcile_orphaned_run_agents(run_id: run.id) end
      ]
      |> Task.async_stream(& &1.(), max_concurrency: 2, timeout: :infinity)
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.any?(results, &match?({:ok, %RunAgent{status: "starting"}}, &1))
    assert Enum.any?(results, &(&1 == []))
    assert %RunAgent{status: "starting"} = Runs.get_run_agent(agent.id)
    assert {:ok, _agent} = Runs.assert_run_agent_lease(agent.id, owner, agent.lease_generation)
  end

  test "restart control atomically advances an interrupted agent and control generation", %{
    run: run
  } do
    old_owner = "fleet:restart-old"
    new_owner = "fleet:restart-new"
    {:ok, [agent]} = Runs.create_run_agents(run, [%{key: "restartable"}])
    {:ok, agent} = Runs.claim_run_agent(agent, old_owner, 60_000)
    {:ok, agent} = Runs.release_run_agent_lease(agent, old_owner, agent.lease_generation)

    assert {:ok, restart} =
             Runs.enqueue_run_agent_control(agent, "restart:1", %{kind: "restart", payload: %{}})

    assert {:ok, {restarted, claimed_restart}} =
             Runs.claim_restart_run_agent_control(agent, new_owner, 60_000)

    assert restarted.status == "starting"
    assert restarted.lease_generation == agent.lease_generation + 1
    assert claimed_restart.id == restart.id
    assert claimed_restart.status == "claimed"
    assert claimed_restart.target_generation == agent.lease_generation
    assert claimed_restart.claim_generation == restarted.lease_generation

    assert {:ok, applied} =
             Runs.resolve_run_agent_control(
               claimed_restart,
               "applied",
               %{"effect" => "restarted"},
               new_owner,
               restarted.lease_generation
             )

    assert applied.status == "applied"
  end

  test "terminal-agent reconciliation applies a claimed cancel left after agent shutdown", %{
    run: run
  } do
    owner = "fleet:cancel-reconcile"

    {:ok, [agent, stale_agent]} =
      Runs.create_run_agents(run, [%{key: "cancel-receipt"}, %{key: "stale-control"}])

    {:ok, agent} = Runs.claim_run_agent(agent, owner, 60_000)

    assert {:ok, cancel} =
             Runs.enqueue_run_agent_control(agent, "cancel:crash-window", %{
               kind: "cancel",
               payload: %{}
             })

    assert {:ok, claimed_cancel} =
             Runs.claim_next_run_agent_control(agent, owner, agent.lease_generation)

    assert claimed_cancel.id == cancel.id

    assert {:ok, cancelled} =
             Runs.release_run_agent_lease(
               agent,
               owner,
               agent.lease_generation,
               "cancelled",
               %{desired_state: "stopped"}
             )

    assert cancelled.status == "cancelled"
    assert Runs.get_run_agent_control(cancel.id).status == "claimed"

    assert {:ok, stale_control} =
             Runs.enqueue_run_agent_control(stale_agent, "steer:terminal-row", %{
               kind: "steer",
               payload: %{"guidance" => "too late"}
             })

    timestamp = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {1, _} =
      from(candidate in RunAgent, where: candidate.id == ^stale_agent.id)
      |> Repo.update_all(
        set: [
          status: "cancelled",
          desired_state: "stopped",
          lease_owner: nil,
          lease_expires_at: nil,
          completed_at: timestamp,
          last_active_at: timestamp
        ]
      )

    :ok = Runs.subscribe(run)

    reconciled = Runs.reconcile_terminal_run_agent_controls(run_id: run.id)

    assert Enum.map(reconciled, &{&1.id, &1.status}) |> Enum.sort() ==
             Enum.sort([{cancel.id, "applied"}, {stale_control.id, "superseded"}])

    control_id = cancel.id

    assert_receive {:run_agent_control_updated, %{id: ^control_id, status: "applied"}}

    stale_control_id = stale_control.id

    assert_receive {:run_agent_control_updated, %{id: ^stale_control_id, status: "superseded"}}

    assert %{
             status: "applied",
             result: %{
               "action" => "cancel",
               "status" => "cancelled",
               "reason" => "terminal_agent_reconciliation"
             }
           } = Runs.get_run_agent_control(cancel.id)

    assert %{status: "superseded", result: %{"reason" => "agent_terminal_or_stopped"}} =
             Runs.get_run_agent_control(stale_control.id)

    assert Runs.reconcile_terminal_run_agent_controls(run_id: run.id) == []
  end

  test "strict legacy control resolution rejects scope confusion", %{run: run} do
    {:ok, pending} =
      Runs.enqueue_control(run, "strict-control", %{kind: "steer", payload: %{"guidance" => "x"}})

    {:ok, claimed} = Runs.claim_control(pending, run.lease_owner)

    assert {:error, {:control_scope_mismatch, :run_id}} =
             Runs.resolve_control(claimed, "applied", %{},
               run_id: Ecto.UUID.generate(),
               worker_id: run.lease_owner,
               kind: "steer"
             )

    assert {:error, {:control_scope_mismatch, :worker_id}} =
             Runs.resolve_control(claimed, "applied", %{},
               run_id: run.id,
               worker_id: "dispatcher:other",
               kind: "steer"
             )

    assert {:error, {:control_scope_mismatch, :kind}} =
             Runs.resolve_control(claimed, "applied", %{},
               run_id: run.id,
               worker_id: run.lease_owner,
               kind: "cancel"
             )

    assert {:ok, applied} =
             Runs.resolve_control(claimed, "applied", %{},
               run_id: run.id,
               worker_id: run.lease_owner,
               kind: "steer"
             )

    assert applied.status == "applied"
  end

  test "durable steering consumption is fenced, ordered, bounded, and exactly once", %{run: run} do
    owner = "fleet:steering-consumer"
    {:ok, [agent]} = Runs.create_run_agents(run, [%{key: "steerable"}])
    {:ok, agent} = Runs.claim_run_agent(agent, owner, 60_000)

    for {key, guidance} <- [{"steer:1", "First"}, {"steer:2", "Second"}] do
      {:ok, _pending} =
        Runs.enqueue_run_agent_control(agent, key, %{
          kind: "steer",
          payload: %{"guidance" => guidance}
        })

      {:ok, claimed} =
        Runs.claim_next_run_agent_control(agent, owner, agent.lease_generation)

      {:ok, _applied} =
        Runs.resolve_run_agent_control(
          claimed,
          "applied",
          %{"action" => "steer", "status" => "queued"},
          owner,
          agent.lease_generation
        )
    end

    assert {:error, :lease_lost} =
             Runs.consume_run_agent_steering_controls(
               agent,
               owner <> "-stale",
               agent.lease_generation
             )

    assert {:ok, [%{"guidance" => "First"} = first]} =
             Runs.consume_run_agent_steering_controls(agent, owner, agent.lease_generation, 1)

    assert is_binary(first["control_id"])

    assert {:ok, [%{"guidance" => "Second"}]} =
             Runs.consume_run_agent_steering_controls(agent, owner, agent.lease_generation)

    assert {:ok, []} =
             Runs.consume_run_agent_steering_controls(agent, owner, agent.lease_generation)

    assert Enum.count(Runs.list_events(run, type: "run.agent_steering_consumed")) == 2
  end

  test "lists a bounded newest-first run-scoped agent control window", %{
    project: project,
    session: session,
    run: run
  } do
    {:ok, [first_agent, second_agent]} =
      Runs.create_run_agents(run, [%{key: "first"}, %{key: "second"}])

    {:ok, first} =
      Runs.enqueue_run_agent_control(first_agent, "receipt:first", %{
        kind: "pause",
        payload: %{}
      })

    {:ok, second} =
      Runs.enqueue_run_agent_control(first_agent, "receipt:second", %{
        kind: "steer",
        payload: %{"guidance" => "Keep the scope narrow"}
      })

    {:ok, third} =
      Runs.enqueue_run_agent_control(second_agent, "receipt:third", %{
        kind: "cancel",
        payload: %{}
      })

    {:ok, other_run} =
      Runs.create_run(%{
        project_id: project.id,
        session_id: session.id,
        objective: "Keep receipt scopes isolated",
        status: "running",
        attempt: 1,
        lease_generation: 1,
        lease_owner: "other-control-window",
        lease_expires_at: DateTime.add(DateTime.utc_now(), 60, :second)
      })

    {:ok, [other_agent]} = Runs.create_run_agents(other_run, [%{key: "other"}])

    {:ok, other_control} =
      Runs.enqueue_run_agent_control(other_agent, "receipt:other", %{
        kind: "pause",
        payload: %{}
      })

    controls = Runs.list_run_agent_controls_for_run(run)
    control_ids = Enum.map(controls, & &1.id)

    assert MapSet.new(control_ids) == MapSet.new([first.id, second.id, third.id])

    assert controls
           |> Enum.filter(&(&1.run_agent_id == first_agent.id))
           |> Enum.map(& &1.id) == [second.id, first.id]

    assert Enum.any?(controls, &(&1.id == third.id and &1.run_agent_id == second_agent.id))
    refute other_control.id in control_ids

    noisy_controls =
      for index <- 1..25 do
        assert {:ok, control} =
                 Runs.enqueue_run_agent_control(first_agent, "receipt:noisy:#{index}", %{
                   kind: "steer",
                   payload: %{"guidance" => "Directive #{index}"}
                 })

        control
      end

    latest_noisy = List.last(noisy_controls)
    bounded = Runs.list_run_agent_controls_for_run(run, limit: 1)

    assert Enum.any?(bounded, &(&1.id == first.id))
    assert Enum.any?(bounded, &(&1.id == latest_noisy.id))
    assert Enum.any?(bounded, &(&1.id == third.id))
    refute Enum.any?(bounded, &(&1.id == second.id))

    assert bounded
           |> Enum.map(&{&1.run_agent_id, &1.kind})
           |> Enum.frequencies()
           |> Map.values()
           |> Enum.all?(&(&1 == 1))

    assert Enum.all?(
             Runs.list_run_agent_controls_for_run(run, status: "pending"),
             &(&1.status == "pending")
           )

    assert [] = Runs.list_run_agent_controls_for_run(Ecto.UUID.generate())
  end

  test "ensure rejects immutable manifest drift and migration checks enforce hashed owners", %{
    run: run
  } do
    assert {:ok, [_agent]} =
             Runs.ensure_run_agents(run, [
               %{key: "manifest", role: "explorer", adapter: "otp.explorer"}
             ])

    assert {:error, {:agent_manifest_conflict, "manifest"}} =
             Runs.ensure_run_agents(run, [
               %{key: "manifest", role: "coder", adapter: "otp.coder"}
             ])

    %{rows: [[agent_sql]]} =
      Repo.query!("SELECT sql FROM sqlite_master WHERE type='table' AND name='run_agents'")

    %{rows: [[control_sql]]} =
      Repo.query!(
        "SELECT sql FROM sqlite_master WHERE type='table' AND name='run_agent_controls'"
      )

    assert agent_sql =~ "length(lease_owner) = 64"
    assert agent_sql =~ "lease_owner NOT GLOB '*[^0-9a-f]*'"
    assert control_sql =~ "length(claim_owner) = 64"
    assert control_sql =~ "claim_owner NOT GLOB '*[^0-9a-f]*'"
  end

  test "agent usage enforces provider-reported cost budget", %{
    project: project,
    session: session,
    run: run
  } do
    {:ok, run} = transition_parent(run, "paused")
    {:ok, run} = transition_parent(run, "running", %{cost_budget_cents: 4})
    {:ok, [agent]} = Runs.create_run_agents(run, [%{key: "costed"}])
    {:ok, agent} = Runs.claim_run_agent(agent, "fleet:cost", 60_000)

    assert {:error, {:cost_budget_exhausted, failed_run}} =
             Runs.record_run_agent_usage(
               agent,
               %{cost_cents: 5},
               "agent.llm",
               lease_owner: "fleet:cost",
               lease_generation: agent.lease_generation
             )

    assert failed_run.status == "failed"
    assert failed_run.cost_cents == 5
    assert failed_run.error_details["budget"] == "cost_cents"
    assert failed_run.lease_owner == run.lease_owner

    assert {:ok, _queued} =
             Runs.create_run(%{
               project_id: project.id,
               session_id: session.id,
               objective: "Queued behind cost-exhausted owner"
             })

    assert :none = Runs.claim_next_run("other-cost-dispatcher")
  end

  test "durable agent mutations fail closed after the parent run terminalizes", %{run: run} do
    owner = "fleet:terminal-parent"
    {:ok, [agent]} = Runs.create_run_agents(run, [%{key: "terminal-parent"}])
    {:ok, claimed} = Runs.claim_run_agent(agent, owner, 60_000)

    {:ok, idle} =
      Runs.transition_run_agent(claimed, "idle", %{},
        lease_owner: owner,
        lease_generation: claimed.lease_generation
      )

    assert {:ok, failed_run} = transition_parent(run, "failed")
    assert failed_run.status == "failed"

    assert {:error, :lease_lost} =
             Runs.heartbeat_run_agent(idle, owner, idle.lease_generation, 60_000, %{
               progress: 40
             })

    assert {:error, {:invalid_transition, "failed", "running"}} =
             Runs.transition_run_agent(idle, "running", %{current_task: "must not start"},
               lease_owner: owner,
               lease_generation: idle.lease_generation
             )

    assert {:error, :lease_lost} =
             Runs.record_run_agent_usage(
               idle,
               %{prompt_tokens: 9, completion_tokens: 4, cost_cents: 3},
               "late.provider",
               lease_owner: owner,
               lease_generation: idle.lease_generation
             )

    persisted_agent = Runs.get_run_agent(idle.id)
    persisted_run = Runs.get_run!(run.id)
    assert persisted_agent.status == "failed"
    assert persisted_agent.progress == 0
    assert persisted_agent.input_tokens == 0
    assert persisted_agent.output_tokens == 0
    assert persisted_run.input_tokens == 0
    assert persisted_run.output_tokens == 0
    assert persisted_run.cost_cents == 0
  end

  test "a parent retry fences every prior-attempt agent claim, control, and active mutation", %{
    run: run
  } do
    old_owner = "fleet:prior-attempt"

    {:ok, [active, restartable, pending]} =
      Runs.create_run_agents(run, [
        %{key: "old-active"},
        %{key: "old-restartable"},
        %{key: "old-pending"}
      ])

    {:ok, active} = Runs.claim_run_agent(active, old_owner, 60_000)
    {:ok, restartable} = Runs.claim_run_agent(restartable, old_owner, 60_000)

    {:ok, restartable} =
      Runs.release_run_agent_lease(
        restartable,
        old_owner,
        restartable.lease_generation,
        "interrupted",
        %{desired_state: "active"}
      )

    assert {:ok, _restart} =
             Runs.enqueue_run_agent_control(restartable, "old-restart", %{
               kind: "restart",
               payload: %{}
             })

    {1, _} =
      Repo.update_all(
        from(parent in IexCode.Runs.Run, where: parent.id == ^run.id),
        inc: [attempt: 1, lease_generation: 1]
      )

    current = Runs.get_run!(run.id)
    assert current.attempt == run.attempt + 1

    assert {:error, :run_lease_lost} = Runs.claim_run_agent(pending, old_owner, 60_000)

    assert {:error, :lease_lost} =
             Runs.heartbeat_run_agent(active, old_owner, active.lease_generation, 60_000)

    assert {:error, :run_lease_lost} =
             Runs.transition_run_agent(active, "idle", %{},
               lease_owner: old_owner,
               lease_generation: active.lease_generation
             )

    assert {:error, :run_lease_lost} =
             Runs.claim_restart_run_agent_control(restartable, old_owner, 60_000)

    assert {:error, :run_lease_lost} =
             Runs.enqueue_run_agent_control(active, "stale-steer", %{
               kind: "steer",
               payload: %{"guidance" => "must not cross attempts"}
             })

    assert {:ok, [current_agent]} =
             Runs.create_run_agents(current, [%{key: "current-attempt"}])

    assert {:error, :lease_not_owned} =
             Runs.terminalize_run_agents(run, "cancelled", %{},
               lease_owner: run.lease_owner,
               run_attempt: run.attempt,
               lease_generation: run.lease_generation
             )

    assert Runs.get_run_agent(current_agent.id).status == "pending"
  end
end
