defmodule IexCode.Research.ProviderBudgetTest do
  use IexCode.DataCase, async: false

  import Ecto.Query

  alias IexCode.{Projects, Repo, Sessions}
  alias IexCode.Research.ProviderBudget
  alias IexCode.Runs.{Run, RunCommand, RunStep, RunStepAttempt}

  @owner "research-budget-owner"
  @foreign_owner "research-budget-foreign"
  @manifest_hash String.duplicate("a", 64)

  setup do
    root = Path.join(System.tmp_dir!(), "research-budget-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    {:ok, project} =
      Projects.create_project(%{
        name: "Research budget #{System.unique_integer([:positive])}",
        root_path: root
      })

    {:ok, session} =
      Sessions.create_session(%{project_id: project.id, title: "Research provider budget"})

    on_exit(fn -> File.rm_rf(root) end)
    %{project: project, session: session}
  end

  test "reserves before use and replays the same semantic reservation idempotently", context do
    %{attempt: attempt} = fixture(context)
    estimate = amounts(1, 6, 2, 3)

    assert {:ok, first} = ProviderBudget.reserve(attempt, @owner, 3, 1, "request-1", estimate)
    assert first.status == "claimed"
    refute first.arguments["authority_hash"] == @owner

    assert {:ok, replayed} =
             ProviderBudget.reserve(attempt, @owner, 3, 1, "request-1", estimate)

    assert replayed.id == first.id
    assert Repo.aggregate(RunCommand, :count) == 1

    assert {:error, :reservation_idempotency_conflict} =
             ProviderBudget.reserve(attempt, @owner, 3, 1, "request-1", amounts(1, 7, 2, 3))
  end

  test "reserve_with_status atomically distinguishes the intent creator", context do
    %{attempt: attempt} = fixture(context)
    estimate = amounts(1, 2, 1, 1)

    assert {:ok, %{created?: true, reservation: first}} =
             ProviderBudget.reserve_with_status(attempt, @owner, 3, 1, "owned-intent", estimate)

    assert {:ok, %{created?: false, reservation: replayed}} =
             ProviderBudget.reserve_with_status(attempt, @owner, 3, 1, "owned-intent", estimate)

    assert replayed.id == first.id

    assert {:error, :worker_authority_required} =
             IexCode.Runs.transition_command(first, "uncertain")

    assert Repo.get!(RunCommand, first.id).status == "claimed"
  end

  test "settlement is fenced, idempotent, and charges actual usage exactly once", context do
    %{attempt: attempt, run: run} = fixture(context)
    assert {:ok, reservation} = reserve(attempt, "settle", amounts(1, 8, 4, 5))
    actual = amounts(1, 5, 2, 3)

    assert {:error, :reservation_authority_lost} =
             ProviderBudget.settle(reservation, @foreign_owner, 3, 1, actual)

    assert {:error, :reservation_authority_lost} =
             ProviderBudget.settle(reservation, @owner, 4, 1, actual)

    assert {:error, :reservation_authority_lost} =
             ProviderBudget.settle(reservation, @owner, 3, 2, actual)

    assert {:ok, first} = ProviderBudget.settle(reservation, @owner, 3, 1, actual)
    assert first.reservation.status == "completed"
    assert %{input_tokens: 5, output_tokens: 2, cost_cents: 3} = first.run

    assert {:ok, replayed} = ProviderBudget.settle(reservation, @owner, 3, 1, actual)
    assert replayed.reservation.id == first.reservation.id
    assert %{input_tokens: 5, output_tokens: 2, cost_cents: 3} = Repo.get!(Run, run.id)

    assert {:error, :settlement_idempotency_conflict} =
             ProviderBudget.settle(reservation, @owner, 3, 1, amounts(1, 4, 2, 3))
  end

  test "reservation enforces step and run budgets transactionally", context do
    %{attempt: attempt} =
      fixture(context,
        token_budget: 12,
        cost_budget_cents: 4,
        caps: amounts(2, 20, 20, 20)
      )

    assert {:ok, _first} = reserve(attempt, "first", amounts(1, 6, 2, 3))

    assert {:error, {:run_budget_exhausted, :tokens}} =
             reserve(attempt, "tokens", amounts(1, 5, 0, 0))

    assert {:error, {:run_budget_exhausted, :cost_cents}} =
             reserve(attempt, "cost", amounts(1, 0, 0, 2))

    assert Repo.aggregate(RunCommand, :count) == 1
  end

  test "settled request usage remains charged against the step request ceiling", context do
    %{attempt: attempt} = fixture(context, caps: amounts(2, 50, 50, 50))

    assert {:ok, first} = reserve(attempt, "one", amounts(1, 5, 1, 1))
    assert {:ok, _receipt} = ProviderBudget.settle(first, @owner, 3, 1, amounts(1, 3, 1, 1))
    assert {:ok, _second} = reserve(attempt, "two", amounts(1, 5, 1, 1))

    assert {:error, {:step_budget_exhausted, :requests}} =
             reserve(attempt, "three", amounts(1, 1, 1, 1))
  end

  test "overrun fails closed without charging or consuming the reservation", context do
    %{attempt: attempt, run: run} = fixture(context)
    assert {:ok, reservation} = reserve(attempt, "overrun", amounts(1, 4, 2, 2))

    assert {:error, :reservation_overrun} =
             ProviderBudget.settle(reservation, @owner, 3, 1, amounts(1, 5, 2, 2))

    assert %{input_tokens: 0, output_tokens: 0, cost_cents: 0} = Repo.get!(Run, run.id)
    assert Repo.get!(RunCommand, reservation.id).status == "claimed"

    assert {:ok, receipt} =
             ProviderBudget.settle(reservation, @owner, 3, 1, amounts(1, 4, 2, 2),
               outcome: :failed
             )

    assert receipt.reservation.status == "failed"
    assert receipt.reservation.error_details == %{"code" => "provider_request_failed"}
  end

  test "provable non-use releases capacity while uncertain usage charges the full reservation",
       context do
    %{attempt: attempt, run: run} = fixture(context, caps: amounts(1, 20, 10, 10))
    estimate = amounts(1, 8, 4, 5)
    assert {:ok, released} = reserve(attempt, "not-sent", estimate)

    assert {:error, :reservation_authority_lost} =
             ProviderBudget.release(released, @foreign_owner, 3, 1)

    assert {:ok, first_release} = ProviderBudget.release(released, @owner, 3, 1)
    assert first_release.status == "cancelled"
    assert {:ok, replayed_release} = ProviderBudget.release(released, @owner, 3, 1)
    assert replayed_release.id == first_release.id

    assert {:error, :release_idempotency_conflict} =
             ProviderBudget.release(released, @owner, 3, 1, :preflight_rejected)

    assert {:ok, uncertain} = reserve(attempt, "maybe-sent", estimate)

    assert {:ok, receipt} =
             ProviderBudget.settle(uncertain, @owner, 3, 1, amounts(0, 0, 0, 0),
               outcome: :uncertain
             )

    assert receipt.reservation.status == "uncertain"
    assert receipt.reservation.error_details == %{"code" => "provider_usage_uncertain"}
    assert %{input_tokens: 8, output_tokens: 4, cost_cents: 5} = Repo.get!(Run, run.id)
  end

  test "settlement receipts participate in idempotency and reject secrets", context do
    %{attempt: attempt} = fixture(context)
    assert {:ok, reservation} = reserve(attempt, "receipt", amounts(1, 4, 2, 2))
    actual = amounts(1, 3, 1, 1)
    receipt = %{"effect_digest" => String.duplicate("a", 64)}

    assert {:ok, settled} =
             ProviderBudget.settle(reservation, @owner, 3, 1, actual, receipt: receipt)

    assert %{"receipt" => ^receipt} = Jason.decode!(settled.reservation.output)

    assert {:ok, _replayed} =
             ProviderBudget.settle(reservation, @owner, 3, 1, actual, receipt: receipt)

    assert {:error, :settlement_idempotency_conflict} =
             ProviderBudget.settle(reservation, @owner, 3, 1, actual,
               receipt: %{"effect_digest" => String.duplicate("b", 64)}
             )

    assert {:error, :invalid_settlement_receipt} =
             ProviderBudget.settle(reservation, @owner, 3, 1, actual,
               receipt: %{"authorization" => "must-not-persist"}
             )
  end

  test "settlement payload is bounded, secret-safe, and participates by digest", context do
    %{attempt: attempt} = fixture(context)
    actual = amounts(1, 2, 1, 1)
    payload = %{"answer" => "durable"}
    assert {:ok, reservation} = reserve(attempt, "payload", amounts(1, 4, 2, 2))

    assert {:ok, settled} =
             ProviderBudget.settle(reservation, @owner, 3, 1, actual, payload: payload)

    assert %{"payload" => ^payload, "payload_digest" => digest} =
             Jason.decode!(settled.reservation.output)

    assert byte_size(digest) == 64

    assert {:ok, _replayed} =
             ProviderBudget.settle(reservation, @owner, 3, 1, actual, payload: payload)

    assert {:error, :settlement_idempotency_conflict} =
             ProviderBudget.settle(reservation, @owner, 3, 1, actual,
               payload: %{"answer" => "changed"}
             )

    assert {:ok, secret_reservation} =
             reserve(attempt, "secret-payload", amounts(1, 4, 2, 2))

    assert {:error, :invalid_settlement_payload} =
             ProviderBudget.settle(secret_reservation, @owner, 3, 1, actual,
               payload: %{"access_token" => "must-not-persist"}
             )

    assert Repo.get!(RunCommand, secret_reservation.id).status == "claimed"

    assert {:ok, oversized_reservation} =
             reserve(attempt, "oversized-payload", amounts(1, 4, 2, 2))

    assert {:error, :invalid_settlement_payload} =
             ProviderBudget.settle(oversized_reservation, @owner, 3, 1, actual,
               payload: %{"answer" => String.duplicate("x", 256_001)}
             )

    assert Repo.get!(RunCommand, oversized_reservation.id).status == "claimed"
  end

  test "uncertain settlement survives terminal parent and expired leases", context do
    %{attempt: attempt, run: run} = fixture(context)
    estimate = amounts(1, 5, 2, 2)
    assert {:ok, reservation} = reserve(attempt, "terminal-parent", estimate)

    Repo.update_all(from(current in Run, where: current.id == ^run.id),
      set: [status: "failed", lease_expires_at: DateTime.add(DateTime.utc_now(), -1, :second)]
    )

    Repo.update_all(from(current in RunStepAttempt, where: current.id == ^attempt.id),
      set: [
        status: "failed",
        lease_owner: nil,
        lease_expires_at: nil,
        completed_at: DateTime.utc_now()
      ]
    )

    assert {:ok, settled} =
             ProviderBudget.settle(reservation, @owner, 3, 1, amounts(0, 0, 0, 0),
               outcome: :uncertain,
               receipt: %{"phase" => "callback_started"}
             )

    assert settled.reservation.status == "uncertain"
    assert %{input_tokens: 5, output_tokens: 2, cost_cents: 2} = Repo.get!(Run, run.id)
  end

  test "paused authority may settle an in-flight request but cannot reserve a new one", context do
    %{attempt: attempt, run: run, step: step} = fixture(context)
    assert {:ok, reservation} = reserve(attempt, "in-flight", amounts(1, 2, 1, 1))

    Repo.update_all(from(current in Run, where: current.id == ^run.id), set: [status: "paused"])

    Repo.update_all(from(current in RunStep, where: current.id == ^step.id),
      set: [status: "paused"]
    )

    Repo.update_all(from(current in RunStepAttempt, where: current.id == ^attempt.id),
      set: [status: "paused"]
    )

    assert {:error, {:run_not_running, "paused"}} =
             reserve(attempt, "new-while-paused", amounts(1, 1, 1, 1))

    assert {:ok, receipt} =
             ProviderBudget.settle(reservation, @owner, 3, 1, amounts(1, 2, 1, 1))

    assert receipt.reservation.status == "completed"
  end

  test "stale generations, owners, leases, and inactive attempts cannot reserve", context do
    %{attempt: attempt, run: run} = fixture(context)
    estimate = amounts(1, 1, 1, 1)

    assert {:error, :run_lease_lost} =
             ProviderBudget.reserve(attempt, @foreign_owner, 3, 1, "foreign", estimate)

    assert {:error, :run_lease_lost} =
             ProviderBudget.reserve(attempt, @owner, 4, 1, "run-generation", estimate)

    assert {:error, :step_lease_lost} =
             ProviderBudget.reserve(attempt, @owner, 3, 2, "step-generation", estimate)

    Repo.update_all(from(current in Run, where: current.id == ^run.id),
      set: [lease_expires_at: DateTime.add(DateTime.utc_now(), -1, :second)]
    )

    assert {:error, :run_lease_lost} =
             ProviderBudget.reserve(attempt, @owner, 3, 1, "expired", estimate)

    assert Repo.aggregate(RunCommand, :count) == 0
  end

  test "concurrent reservations cannot oversubscribe a one-request cap", context do
    %{attempt: attempt} = fixture(context, caps: amounts(1, 10, 10, 10))

    replies =
      ["one", "two"]
      |> Task.async_stream(
        &reserve(attempt, &1, amounts(1, 1, 1, 1)),
        max_concurrency: 2,
        ordered: false,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, reply} -> reply end)

    assert Enum.count(replies, &match?({:ok, %RunCommand{}}, &1)) == 1

    assert Enum.count(
             replies,
             &match?({:error, {:step_budget_exhausted, :requests}}, &1)
           ) == 1

    assert Repo.aggregate(RunCommand, :count) == 1
  end

  test "counter overflow and malformed estimates fail closed", context do
    max = 9_007_199_254_740_991
    %{attempt: attempt, run: run} = fixture(context, caps: amounts(2, max, max, max))

    Repo.update_all(from(current in Run, where: current.id == ^run.id),
      set: [input_tokens: max]
    )

    assert {:error, :budget_counter_overflow} =
             reserve(attempt, "overflow", amounts(1, 1, 0, 0))

    assert {:error, :invalid_reservation_fields} =
             ProviderBudget.reserve(attempt, @owner, 3, 1, "unknown", %{
               requests: 1,
               authorization: 1
             })

    assert {:error, :invalid_reservation_amount} =
             reserve(attempt, "negative", amounts(1, -1, 0, 0))

    assert Repo.aggregate(RunCommand, :count) == 0
  end

  test "reconciliation terminalizes abandoned claims and charges the full reservation", context do
    %{attempt: attempt, run: run} = fixture(context)
    estimate = amounts(1, 5, 2, 2)
    assert {:ok, reservation} = reserve(attempt, "provider-effect:abandoned", estimate)

    Repo.update_all(from(current in Run, where: current.id == ^run.id),
      set: [lease_expires_at: DateTime.add(DateTime.utc_now(), -1, :second)]
    )

    assert [{id, {:ok, reconciled}}] = ProviderBudget.reconcile_claimed()
    assert id == reservation.id
    assert reconciled.status == "uncertain"
    assert reconciled.error_details == %{"code" => "provider_usage_uncertain"}
    assert %{input_tokens: 5, output_tokens: 2, cost_cents: 2} = Repo.get!(Run, run.id)
    assert [] = ProviderBudget.reconcile_claimed()
  end

  defp reserve(attempt, key, estimate),
    do: ProviderBudget.reserve(attempt, @owner, 3, 1, key, estimate)

  defp fixture(context, opts \\ []) do
    timestamp = DateTime.utc_now() |> DateTime.truncate(:second)
    caps = Keyword.get(opts, :caps, amounts(4, 20, 10, 10))

    {:ok, run} =
      %Run{project_id: context.project.id, session_id: context.session.id}
      |> Run.create_changeset(%{
        objective: "Research provider budget",
        kind: "deep_research",
        mode: "research",
        execution_engine: "dag_v1",
        manifest_hash: @manifest_hash,
        status: "running",
        attempt: 2,
        lease_generation: 3,
        lease_owner: @owner,
        lease_expires_at: DateTime.add(timestamp, 60, :second),
        heartbeat_at: timestamp,
        started_at: timestamp,
        token_budget: opts[:token_budget],
        cost_budget_cents: opts[:cost_budget_cents]
      })
      |> Repo.insert()

    step =
      %RunStep{run_id: run.id}
      |> RunStep.create_changeset(%{
        key: "research.search.grounded.1.test",
        kind: "research_grounded_search",
        title: "Grounded provider request",
        status: "running",
        attempt: 1,
        max_attempts: 2,
        params: %{
          "max_search_calls" => caps.requests,
          "max_input_tokens" => caps.input_tokens,
          "max_output_tokens" => caps.output_tokens,
          "max_cost_cents" => caps.cost_cents
        },
        handler_version: 1,
        effect_class: "provider",
        replay_policy: "never",
        resource_spec: %{"contract" => "research_provider_v1"},
        timeout_ms: 30_000,
        heartbeat_at: timestamp,
        started_at: timestamp
      })
      |> Repo.insert!()

    owner_hash = :crypto.hash(:sha256, @owner) |> Base.encode16(case: :lower)

    attempt =
      %RunStepAttempt{run_id: run.id, run_step_id: step.id}
      |> RunStepAttempt.changeset(%{
        run_attempt: 2,
        run_lease_generation: 3,
        attempt: 1,
        execution_key: "2:research.search.grounded.1.test:1",
        manifest_hash: @manifest_hash,
        handler_kind: step.kind,
        handler_version: 1,
        effect_class: "provider",
        replay_policy: "never",
        status: "running",
        run_owner: owner_hash,
        claim_owner: owner_hash,
        lease_owner: owner_hash,
        lease_generation: 1,
        lease_expires_at: DateTime.add(timestamp, 30, :second),
        heartbeat_at: timestamp,
        started_at: timestamp
      })
      |> Repo.insert!()

    %{run: run, step: step, attempt: attempt}
  end

  defp amounts(requests, input, output, cost) do
    %{requests: requests, input_tokens: input, output_tokens: output, cost_cents: cost}
  end
end
