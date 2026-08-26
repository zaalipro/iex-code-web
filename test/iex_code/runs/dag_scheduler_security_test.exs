defmodule IexCode.Runs.DagSchedulerSecurityTest do
  use IexCode.DataCase, async: false

  import Ecto.Query

  alias IexCode.{Projects, Repo, Sessions}

  alias IexCode.Runs.{
    DagManifest,
    DagScheduler,
    DagStepHandlers,
    DagStepRegistry,
    Run,
    RunStep,
    RunStepAttempt
  }

  @owner "dag-security-owner"
  @foreign_owner "dag-security-foreign"

  setup do
    root = Path.join(System.tmp_dir!(), "iex-dag-security-#{System.unique_integer([:positive])}")
    outside = root <> "-outside"
    File.mkdir_p!(root)
    File.mkdir_p!(outside)
    File.write!(Path.join(root, "inside.txt"), "inside")
    File.write!(Path.join(outside, "outside.txt"), "outside")

    {:ok, project} =
      Projects.create_project(%{
        name: "DAG Security #{System.unique_integer([:positive])}",
        root_path: root
      })

    {:ok, session} = Sessions.create_session(%{project_id: project.id, title: "DAG security"})

    on_exit(fn ->
      File.rm_rf(root)
      File.rm_rf(outside)
    end)

    %{project: project, session: session, root: root, outside: outside}
  end

  test "parent and step lease credentials fence every active operation", context do
    {run, _steps} = dag_fixture(context)

    assert {:error, :run_lease_lost} = DagScheduler.claim_ready(run, @foreign_owner, 1)
    assert {:error, :run_lease_lost} = DagScheduler.claim_ready(run, @owner, 2)
    assert {:ok, claim} = DagScheduler.claim_ready(run, @owner, 1)

    assert {:error, :run_lease_lost} =
             DagScheduler.heartbeat(claim.attempt, @foreign_owner, 1, 1)

    assert {:error, :run_lease_lost} =
             DagScheduler.heartbeat(claim.attempt, @owner, 2, 1)

    assert {:error, :step_lease_lost} =
             DagScheduler.checkpoint(claim.attempt, @owner, 1, 2, %{"cursor" => 1}, 20)

    Repo.update_all(from(attempt in RunStepAttempt, where: attempt.id == ^claim.attempt.id),
      set: [lease_expires_at: DateTime.add(DateTime.utc_now(), -1, :second)]
    )

    assert {:error, :step_lease_expired} =
             DagScheduler.complete(claim.attempt, @owner, 1, 1, %{"ok" => true})
  end

  test "an expired parent lease cannot claim, heartbeat, checkpoint, or complete", context do
    {run, _steps} = dag_fixture(context)
    assert {:ok, claim} = DagScheduler.claim_ready(run, @owner, 1)

    Repo.update_all(from(current in Run, where: current.id == ^run.id),
      set: [lease_expires_at: DateTime.add(DateTime.utc_now(), -1, :microsecond)]
    )

    assert {:error, :run_lease_lost} = DagScheduler.claim_ready(run, @owner, 1)
    assert {:error, :run_lease_lost} = DagScheduler.heartbeat(claim.attempt, @owner, 1, 1)

    assert {:error, :run_lease_lost} =
             DagScheduler.checkpoint(claim.attempt, @owner, 1, 1, %{"cursor" => 1}, 20)

    assert {:error, :run_lease_lost} =
             DagScheduler.complete(claim.attempt, @owner, 1, 1, %{"ok" => true})
  end

  test "same-digest completion cannot be used by a foreign owner or stale generation", context do
    {run, _steps} = dag_fixture(context)
    assert {:ok, claim} = DagScheduler.claim_ready(run, @owner, 1)
    result = %{"ok" => true}

    assert {:ok, completed} = DagScheduler.complete(claim.attempt, @owner, 1, 1, result)
    assert completed.status == "completed"
    assert {:ok, replayed} = DagScheduler.complete(claim.attempt, @owner, 1, 1, result)
    assert replayed.id == completed.id

    assert {:error, :run_lease_lost} =
             DagScheduler.complete(claim.attempt, @foreign_owner, 1, 1, result)

    assert {:error, :stale_run_generation} =
             DagScheduler.complete(claim.attempt, @owner, 2, 1, result)
  end

  test "terminalization closes the active-attempt TOCTOU window", context do
    {run, _steps} = dag_fixture(context)
    assert {:ok, claim} = DagScheduler.claim_ready(run, @owner, 1)
    assert {:ok, _receipt} = DagScheduler.terminalize_active(run, @owner, 1, "cancelled")

    assert {:error, :step_attempt_not_active} =
             DagScheduler.heartbeat(claim.attempt, @owner, 1, 1)

    assert {:error, :step_attempt_not_active} =
             DagScheduler.checkpoint(claim.attempt, @owner, 1, 1, %{"cursor" => 1}, 20)

    assert {:error, :step_attempt_not_active} =
             DagScheduler.complete(claim.attempt, @owner, 1, 1, %{"ok" => true})
  end

  test "secret-shaped params, checkpoints, and results fail closed", context do
    secret_step =
      step(%{"access_token" => "must-not-persist"})

    assert {:error, {:invalid_dag_step, 0, :secret_payload_forbidden}} =
             DagManifest.normalize([secret_step])

    for camel_case_key <- ~w(accessToken apiKey privateKey authToken capabilityToken) do
      assert {:error, {:invalid_dag_step, 0, :secret_payload_forbidden}} =
               DagManifest.normalize([step(%{camel_case_key => "must-not-persist"})])
    end

    {run, _steps} = dag_fixture(context)
    assert {:ok, claim} = DagScheduler.claim_ready(run, @owner, 1)

    assert {:error, :secret_payload_forbidden} =
             DagScheduler.checkpoint(
               claim.attempt,
               @owner,
               1,
               1,
               %{"nested" => [%{"private_key" => "must-not-persist"}]},
               20
             )

    assert {:error, :secret_payload_forbidden} =
             DagScheduler.complete(claim.attempt, @owner, 1, 1, %{
               "credential" => "must-not-persist"
             })

    persisted = Repo.get!(RunStepAttempt, claim.attempt.id)
    assert is_nil(persisted.checkpoint)
    assert is_nil(persisted.result)
  end

  test "failure reasons are reduced to bounded codes without persisting details", context do
    {run, _steps} = dag_fixture(context)
    assert {:ok, claim} = DagScheduler.claim_ready(run, @owner, 1)

    assert {:ok, failed} =
             DagScheduler.fail(
               claim.attempt,
               @owner,
               1,
               1,
               {:provider_failure, %{authorization: "Bearer must-not-persist"}}
             )

    encoded = inspect(failed, limit: :infinity)
    refute encoded =~ "must-not-persist"
    assert failed.error_message == "provider_failure"
    assert failed.error_details == %{"code" => "provider_failure"}
  end

  test "manifest and complete handler descriptor contracts are immutable", context do
    {run, [step]} = dag_fixture(context)

    Repo.update_all(from(current in RunStep, where: current.id == ^step.id),
      set: [title: "drifted"]
    )

    assert {:error, :manifest_drift} = DagScheduler.claim_ready(run, @owner, 1)

    {other_run, [other_step]} = dag_fixture(context)

    for {field, forged} <- [
          {:resource_spec, %{"contract" => "forged"}},
          {:timeout_ms, 1},
          {:handler_version, 999},
          {:effect_class, "provider"},
          {:replay_policy, "never"}
        ] do
      Repo.update_all(from(current in RunStep, where: current.id == ^other_step.id),
        set: [{field, forged}]
      )

      assert {:error, :handler_descriptor_drift} =
               DagScheduler.claim_ready(other_run, @owner, 1)

      descriptor = DagStepRegistry.descriptor!(other_step.kind)

      Repo.update_all(from(current in RunStep, where: current.id == ^other_step.id),
        set: [
          resource_spec: %{"contract" => descriptor.resource_contract},
          timeout_ms: descriptor.default_timeout_ms,
          handler_version: descriptor.version,
          effect_class: Atom.to_string(descriptor.effect_class),
          replay_policy: Atom.to_string(descriptor.replay_policy)
        ]
      )
    end
  end

  test "cross-run attempt scope is rejected by the database", context do
    {run, [step]} = dag_fixture(context)
    {other_run, _other_steps} = dag_fixture(context)
    descriptor = DagStepRegistry.descriptor!(step.kind)
    timestamp = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    owner_hash = :crypto.hash(:sha256, @owner) |> Base.encode16(case: :lower)

    changeset =
      %RunStepAttempt{run_id: other_run.id, run_step_id: step.id}
      |> RunStepAttempt.changeset(%{
        run_attempt: 1,
        run_lease_generation: 1,
        attempt: 1,
        execution_key: "cross-run",
        manifest_hash: run.manifest_hash,
        handler_kind: step.kind,
        handler_version: descriptor.version,
        effect_class: Atom.to_string(descriptor.effect_class),
        replay_policy: Atom.to_string(descriptor.replay_policy),
        status: "running",
        run_owner: owner_hash,
        claim_owner: owner_hash,
        lease_owner: owner_hash,
        lease_generation: 1,
        lease_expires_at: DateTime.add(timestamp, 30, :second),
        heartbeat_at: timestamp,
        started_at: timestamp
      })

    assert_raise Exqlite.Error, ~r/run_step_attempt_scope_mismatch/, fn ->
      Repo.insert!(changeset)
    end
  end

  test "persisted attempt ownership and step target are immutable", context do
    {run, [_step]} = dag_fixture(context)
    assert {:ok, claim} = DagScheduler.claim_ready(run, @owner, 1)
    {other_run, [other_step]} = dag_fixture(context)

    # Move both columns to an otherwise valid same-run pair. The older scope
    # trigger therefore permits the shape, leaving the ownership-immutability
    # trigger as the invariant that rejects reparenting the persisted attempt.
    assert_raise Exqlite.Error, ~r/run_step_attempt_target_immutable/, fn ->
      Repo.query!(
        "UPDATE run_step_attempts SET run_id = ?, run_step_id = ? WHERE id = ?",
        [other_run.id, other_step.id, claim.attempt.id]
      )
    end
  end

  test "canonical path resolution blocks read-handler symlink escapes", context do
    File.ln_s!(context.outside, Path.join(context.root, "escape"))

    execution_context = %{
      project_root: context.root,
      cancelled?: fn -> false end
    }

    assert {:error, :outside_workspace} =
             DagStepHandlers.ReadFile.execute(
               %{"path" => "escape/outside.txt"},
               execution_context
             )

    assert {:error, :outside_workspace} =
             DagStepHandlers.ProjectInventory.execute(%{"path" => "escape"}, execution_context)
  end

  test "read handler refuses common credential and private-key paths", context do
    execution_context = %{project_root: context.root, cancelled?: fn -> false end}

    for path <- [
          ".env",
          ".env.production",
          ".git/config",
          ".ssh/id_ed25519",
          "config/prod.secret.exs",
          "credentials.json",
          "certs/client.pem"
        ] do
      assert {:error, {:params, :sensitive_path_forbidden}} =
               DagStepHandlers.ReadFile.validate_params(%{"path" => path}, [])

      assert {:error, :sensitive_path_forbidden} =
               DagStepHandlers.ReadFile.execute(%{"path" => path}, execution_context)

      assert {:error, :sensitive_path_forbidden} =
               DagStepHandlers.ProjectInventory.execute(%{"path" => path}, execution_context)
    end
  end

  test "closed registry rejects raw module names and concurrent claim creates one attempt",
       context do
    assert :error = DagStepRegistry.fetch("Elixir.System")
    assert :error = DagStepRegistry.fetch("shell")

    {run, _steps} = dag_fixture(context)

    replies =
      1..2
      |> Task.async_stream(
        fn _ -> DagScheduler.claim_ready(run, @owner, 1) end,
        max_concurrency: 2,
        ordered: false,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, reply} -> reply end)

    assert Enum.count(replies, &match?({:ok, _claim}, &1)) == 1
    assert Enum.count(replies, &(&1 == :none)) == 1
    assert [_attempt] = DagScheduler.list_attempts(run)
  end

  test "an old reconciliation cutoff cannot overwrite a renewed step lease", context do
    {run, _steps} = dag_fixture(context)
    assert {:ok, claim} = DagScheduler.claim_ready(run, @owner, 1, lease_ms: 1_000)
    stale_cutoff = claim.attempt.lease_expires_at

    assert {:ok, renewed} = DagScheduler.heartbeat(claim.attempt, @owner, 1, 1, 30_000)
    assert DateTime.compare(renewed.lease_expires_at, stale_cutoff) == :gt
    assert [] = DagScheduler.reconcile_expired(stale_cutoff)
    assert Repo.get!(RunStepAttempt, claim.attempt.id).status == "running"
    assert Repo.get!(RunStep, claim.step.id).status == "running"
  end

  test "expired parent authority prevents an expired-step reconciler from retrying work",
       context do
    {run, _steps} = dag_fixture(context)
    assert {:ok, claim} = DagScheduler.claim_ready(run, @owner, 1)
    expired_at = DateTime.add(DateTime.utc_now(), -1, :second)

    Repo.update_all(from(current in Run, where: current.id == ^run.id),
      set: [lease_expires_at: expired_at]
    )

    Repo.update_all(from(attempt in RunStepAttempt, where: attempt.id == ^claim.attempt.id),
      set: [lease_expires_at: expired_at]
    )

    assert [{:ok, interrupted}] = DagScheduler.reconcile_expired(DateTime.utc_now())
    assert interrupted.status == "interrupted"
    assert Repo.get!(RunStep, claim.step.id).status == "interrupted"
    assert {:error, :run_lease_lost} = DagScheduler.claim_ready(run, @owner, 1)
  end

  defp dag_fixture(context) do
    manifest = [step(%{"path" => "inside.txt"})]
    {:ok, [normalized]} = DagManifest.normalize(manifest)
    {:ok, manifest_hash} = DagManifest.hash(manifest)
    timestamp = DateTime.utc_now() |> DateTime.truncate(:second)

    {:ok, run} =
      %Run{project_id: context.project.id, session_id: context.session.id}
      |> Run.create_changeset(%{
        objective: "Security-test DAG",
        kind: "analysis",
        mode: "workflow",
        execution_engine: "dag_v1",
        manifest_hash: manifest_hash,
        status: "running",
        attempt: 1,
        lease_generation: 1,
        lease_owner: @owner,
        lease_expires_at: DateTime.add(timestamp, 60, :second),
        heartbeat_at: timestamp,
        started_at: timestamp
      })
      |> Repo.insert()

    descriptor = DagStepRegistry.descriptor!(normalized.kind)

    persisted_step =
      %RunStep{run_id: run.id}
      |> RunStep.create_changeset(%{
        key: normalized.key,
        kind: normalized.kind,
        title: normalized.title,
        status: normalized.status,
        position: normalized.position,
        max_attempts: normalized.max_attempts,
        depends_on: normalized.depends_on,
        params: normalized.params,
        handler_version: descriptor.version,
        effect_class: Atom.to_string(descriptor.effect_class),
        replay_policy: Atom.to_string(descriptor.replay_policy),
        resource_spec: %{"contract" => descriptor.resource_contract},
        timeout_ms: descriptor.default_timeout_ms
      })
      |> Repo.insert!()

    {run, [persisted_step]}
  end

  defp step(params) do
    %{
      key: "read",
      kind: "read_file",
      title: "Read file",
      params: params,
      max_attempts: 1
    }
  end
end
