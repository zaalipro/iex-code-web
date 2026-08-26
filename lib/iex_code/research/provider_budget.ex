defmodule IexCode.Research.ProviderBudget do
  @moduledoc """
  Durable pre-use budget reservations for research DAG provider handlers.

  Reservations reuse the run command ledger and never contain raw lease credentials.
  Both reservation and settlement are transactionally fenced to the run attempt,
  run lease generation, step attempt generation, and hashed lease owner.
  """

  import Ecto.Query, warn: false

  alias IexCode.Repo
  alias IexCode.Runs.{DagPayload, Run, RunCommand, RunStep, RunStepAttempt}

  @tool_name "research.provider_budget"
  @ledger_prefix "research-budget:"
  @max_idempotency_bytes 160
  @max_receipt_bytes 4_096
  @max_payload_bytes 256_000
  @max_counter 9_007_199_254_740_991
  @dimensions ~w(requests input_tokens output_tokens cost_cents)

  def reserve(attempt_or_id, owner, run_generation, step_generation, idempotency_key, estimate)
      when is_binary(owner) and owner != "" and is_integer(run_generation) and
             is_integer(step_generation) and is_binary(idempotency_key) and is_map(estimate) do
    case reserve_with_status(
           attempt_or_id,
           owner,
           run_generation,
           step_generation,
           idempotency_key,
           estimate
         ) do
      {:ok, %{reservation: reservation}} -> {:ok, reservation}
      {:error, reason} -> {:error, reason}
    end
  end

  def reserve(_attempt, _owner, _run_generation, _step_generation, _key, _estimate),
    do: {:error, :invalid_provider_reservation}

  @doc "Atomically reports whether this caller durably created the provider intent."
  def reserve_with_status(
        attempt_or_id,
        owner,
        run_generation,
        step_generation,
        idempotency_key,
        estimate
      )
      when is_binary(owner) and owner != "" and is_integer(run_generation) and
             is_integer(step_generation) and is_binary(idempotency_key) and is_map(estimate) do
    with :ok <- validate_idempotency_key(idempotency_key),
         {:ok, estimate} <- normalize_amounts(estimate, require_request?: true) do
      transaction(fn ->
        {run, step, attempt} =
          load_active_authority!(attempt_or_id, owner, run_generation, step_generation, true)

        ledger_key = @ledger_prefix <> idempotency_key
        envelope = envelope(attempt, owner, estimate)
        digest = reservation_digest!(envelope, step.id)

        case Repo.get_by(RunCommand, run_id: run.id, idempotency_key: ledger_key) do
          %RunCommand{} = existing ->
            if reservation_matches?(existing, digest),
              do: %{reservation: existing, created?: false},
              else: Repo.rollback(:reservation_idempotency_conflict)

          nil ->
            assert_capacity!(run, step, estimate)
            timestamp = now_second()

            reservation =
              %RunCommand{run_id: run.id, run_step_id: step.id}
              |> RunCommand.changeset(%{
                idempotency_key: ledger_key,
                tool_name: @tool_name,
                status: "claimed",
                arguments: Map.put(envelope, "semantic_digest", digest),
                attempt: 1,
                max_attempts: 1,
                claimed_at: timestamp,
                heartbeat_at: timestamp
              })
              |> insert!()

            %{reservation: reservation, created?: true}
        end
      end)
    end
  end

  def reserve_with_status(
        _attempt,
        _owner,
        _run_generation,
        _step_generation,
        _key,
        _estimate
      ),
      do: {:error, :invalid_provider_reservation}

  def settle(
        reservation_or_id,
        owner,
        run_generation,
        step_generation,
        actual,
        opts \\ []
      )

  def settle(reservation_or_id, owner, run_generation, step_generation, actual, opts)
      when is_binary(owner) and owner != "" and is_integer(run_generation) and
             is_integer(step_generation) and is_map(actual) and is_list(opts) do
    with {:ok, actual} <- normalize_amounts(actual, require_request?: false),
         {:ok, outcome} <- normalize_outcome(opts[:outcome]),
         {:ok, receipt} <- normalize_receipt(Keyword.get(opts, :receipt)),
         {:ok, payload, payload_digest} <- normalize_payload(Keyword.get(opts, :payload)) do
      transaction(fn ->
        reservation = load_reservation!(reservation_or_id)
        arguments = reservation.arguments || %{}
        assert_reservation_authority!(arguments, owner, run_generation, step_generation)
        assert_reservation_lineage!(reservation, arguments, run_generation)
        charged = charged_amounts(actual, arguments, outcome)

        settlement = %{"actual" => stringify_amounts(charged), "outcome" => outcome}
        settlement = if receipt, do: Map.put(settlement, "receipt", receipt), else: settlement

        settlement =
          if payload_digest,
            do: Map.put(settlement, "payload_digest", payload_digest),
            else: settlement

        actual_digest = digest!(settlement)

        cond do
          reservation.status in ["completed", "failed", "uncertain"] ->
            if settled_matches?(reservation, actual_digest),
              do: settlement_receipt(reservation),
              else: Repo.rollback(:settlement_idempotency_conflict)

          reservation.status != "claimed" ->
            Repo.rollback(:reservation_not_active)

          true ->
            if outcome != "uncertain" do
              {_run, _step, _attempt} =
                load_active_authority!(
                  Map.fetch!(arguments, "attempt_id"),
                  owner,
                  run_generation,
                  step_generation,
                  false
                )
            end

            estimate = Map.fetch!(arguments, "estimate")
            assert_within_reservation!(charged, estimate)
            run = Repo.get!(Run, reservation.run_id)
            updated_run = apply_actual!(run, charged)
            timestamp = now_second()

            output =
              %{
                "actual" => charged,
                "digest" => actual_digest,
                "outcome" => outcome
              }
              |> maybe_put_receipt(receipt)
              |> maybe_put_payload(payload, payload_digest)
              |> Jason.encode!()

            updated =
              reservation
              |> RunCommand.changeset(%{
                status: settlement_status(outcome),
                output: output,
                error_message: settlement_error_message(outcome),
                error_details: settlement_error_details(outcome),
                heartbeat_at: timestamp,
                completed_at: timestamp
              })
              |> update!()

            %{reservation: updated, run: updated_run}
        end
      end)
    end
  end

  def settle(_reservation, _owner, _run_generation, _step_generation, _actual, _opts),
    do: {:error, :invalid_provider_settlement}

  def release(reservation_or_id, owner, run_generation, step_generation, reason \\ :not_sent)

  def release(reservation_or_id, owner, run_generation, step_generation, reason)
      when is_binary(owner) and owner != "" and is_integer(run_generation) and
             is_integer(step_generation) and reason in [:not_sent, :preflight_rejected] do
    transaction(fn ->
      reservation = load_reservation!(reservation_or_id)
      arguments = reservation.arguments || %{}
      assert_reservation_authority!(arguments, owner, run_generation, step_generation)
      assert_reservation_lineage!(reservation, arguments, run_generation)
      reason = Atom.to_string(reason)
      digest = digest!(%{"release" => reason})

      cond do
        reservation.status == "cancelled" ->
          if released_matches?(reservation, digest),
            do: reservation,
            else: Repo.rollback(:release_idempotency_conflict)

        reservation.status != "claimed" ->
          Repo.rollback(:reservation_not_releasable)

        true ->
          {_run, _step, _attempt} =
            load_active_authority!(
              Map.fetch!(arguments, "attempt_id"),
              owner,
              run_generation,
              step_generation,
              false
            )

          timestamp = now_second()

          reservation
          |> RunCommand.changeset(%{
            status: "cancelled",
            output: Jason.encode!(%{"digest" => digest, "release" => reason}),
            error_message: "provider_request_not_sent",
            error_details: %{"code" => "provider_request_not_sent"},
            heartbeat_at: timestamp,
            completed_at: timestamp
          })
          |> update!()
      end
    end)
  end

  def release(_reservation, _owner, _run_generation, _step_generation, _reason),
    do: {:error, :invalid_provider_release}

  @doc "Conservatively terminalizes abandoned claimed effects without replaying them."
  def reconcile_claimed(opts \\ [])

  def reconcile_claimed(opts) when is_list(opts) do
    cutoff = Keyword.get(opts, :cutoff, DateTime.utc_now())
    limit = opts |> Keyword.get(:limit, 2_048) |> max(1) |> min(2_048)

    if match?(%DateTime{}, cutoff) do
      RunCommand
      |> where([command], command.tool_name == @tool_name and command.status == "claimed")
      |> order_by([command], asc: command.claimed_at, asc: command.id)
      |> limit(^limit)
      |> Repo.all()
      |> Enum.map(fn reservation -> {reservation.id, reconcile_one(reservation.id, cutoff)} end)
    else
      []
    end
  end

  def reconcile_claimed(_opts), do: []

  defp reconcile_one(reservation_id, cutoff) do
    transaction(fn ->
      reservation = load_reservation!(reservation_id)

      cond do
        reservation.status != "claimed" ->
          reservation

        not abandoned_reservation?(reservation, cutoff) ->
          :active

        true ->
          arguments = reservation.arguments || %{}
          estimate = validate_ledger_amounts!(Map.fetch!(arguments, "estimate"))

          charged =
            Map.new(@dimensions, fn dimension ->
              {String.to_existing_atom(dimension), Map.fetch!(estimate, dimension)}
            end)

          receipt = %{
            "effect_digest" => effect_digest(reservation.idempotency_key),
            "phase" => "reconciled_abandoned_claim"
          }

          settlement = %{
            "actual" => stringify_amounts(charged),
            "outcome" => "uncertain",
            "receipt" => receipt
          }

          actual_digest = digest!(settlement)
          run = Repo.get!(Run, reservation.run_id)
          _updated_run = apply_actual!(run, charged)
          timestamp = now_second()

          reservation
          |> RunCommand.changeset(%{
            status: "uncertain",
            output:
              Jason.encode!(%{
                "actual" => charged,
                "digest" => actual_digest,
                "outcome" => "uncertain",
                "receipt" => receipt
              }),
            error_message: "provider_usage_uncertain",
            error_details: %{"code" => "provider_usage_uncertain"},
            heartbeat_at: timestamp,
            completed_at: timestamp
          })
          |> update!()
      end
    end)
  end

  defp abandoned_reservation?(reservation, cutoff) do
    arguments = reservation.arguments || %{}
    run = Repo.get(Run, reservation.run_id)
    attempt = Repo.get(RunStepAttempt, arguments["attempt_id"])

    is_nil(run) or is_nil(attempt) or run.status not in ["running", "paused"] or
      attempt.status not in ["running", "paused"] or
      run.attempt != arguments["run_attempt"] or
      run.lease_generation != arguments["run_generation"] or
      attempt.run_lease_generation != arguments["run_generation"] or
      attempt.lease_generation != arguments["step_generation"] or
      not live_timestamp?(run.lease_expires_at, cutoff) or
      not live_timestamp?(attempt.lease_expires_at, cutoff)
  end

  defp effect_digest(@ledger_prefix <> "provider-effect:" <> digest), do: digest
  defp effect_digest(_key), do: "unknown"

  defp load_active_authority!(
         attempt_or_id,
         owner,
         run_generation,
         step_generation,
         require_running?
       ) do
    attempt = load_attempt!(attempt_or_id)
    run = Repo.get!(Run, attempt.run_id)
    step = Repo.get!(RunStep, attempt.run_step_id)
    timestamp = DateTime.utc_now()

    cond do
      step.run_id != run.id ->
        Repo.rollback(:attempt_scope_mismatch)

      run.execution_engine != "dag_v1" ->
        Repo.rollback(:not_a_dag_run)

      require_running? and run.status != "running" ->
        Repo.rollback({:run_not_running, run.status})

      run.status not in ["running", "paused"] ->
        Repo.rollback({:run_not_active, run.status})

      run.attempt != attempt.run_attempt ->
        Repo.rollback(:stale_run_attempt)

      run.lease_generation != run_generation ->
        Repo.rollback(:run_lease_lost)

      attempt.run_lease_generation != run_generation ->
        Repo.rollback(:stale_run_generation)

      run.lease_owner != owner ->
        Repo.rollback(:run_lease_lost)

      not live_timestamp?(run.lease_expires_at, timestamp) ->
        Repo.rollback(:run_lease_lost)

      not secure_owner?(attempt.run_owner, owner) ->
        Repo.rollback(:run_lease_lost)

      not secure_owner?(attempt.claim_owner, owner) ->
        Repo.rollback(:step_lease_lost)

      require_running? and attempt.status != "running" ->
        Repo.rollback(:step_attempt_not_running)

      attempt.status not in ["running", "paused"] ->
        Repo.rollback(:step_attempt_not_active)

      attempt.lease_generation != step_generation ->
        Repo.rollback(:step_lease_lost)

      not secure_owner?(attempt.lease_owner, owner) ->
        Repo.rollback(:step_lease_lost)

      not live_timestamp?(attempt.lease_expires_at, timestamp) ->
        Repo.rollback(:step_lease_expired)

      true ->
        {run, step, attempt}
    end
  end

  defp assert_capacity!(run, step, estimate) do
    caps = step_caps(step)
    reserved_for_run = ledger_amounts(run.id, nil, false)
    reserved_for_step = ledger_amounts(run.id, step.id, true)

    assert_dimension!(:requests, reserved_for_step.requests, estimate.requests, caps.requests)

    assert_dimension!(
      :input_tokens,
      reserved_for_step.input_tokens,
      estimate.input_tokens,
      caps.input_tokens
    )

    assert_dimension!(
      :output_tokens,
      reserved_for_step.output_tokens,
      estimate.output_tokens,
      caps.output_tokens
    )

    assert_dimension!(
      :cost_cents,
      reserved_for_step.cost_cents,
      estimate.cost_cents,
      caps.cost_cents
    )

    used_tokens = safe_add!(run.input_tokens || 0, run.output_tokens || 0)
    reserved_tokens = safe_add!(reserved_for_run.input_tokens, reserved_for_run.output_tokens)
    estimate_tokens = safe_add!(estimate.input_tokens, estimate.output_tokens)

    assert_optional_budget!(
      :tokens,
      used_tokens,
      reserved_tokens,
      estimate_tokens,
      run.token_budget
    )

    assert_optional_budget!(
      :cost_cents,
      run.cost_cents || 0,
      reserved_for_run.cost_cents,
      estimate.cost_cents,
      run.cost_budget_cents
    )
  end

  defp ledger_amounts(run_id, step_id, include_settled?) do
    statuses =
      if include_settled?, do: ["claimed", "completed", "failed", "uncertain"], else: ["claimed"]

    query =
      from command in RunCommand,
        where:
          command.run_id == ^run_id and command.tool_name == @tool_name and
            command.status in ^statuses,
        select: {command.status, command.arguments, command.output},
        limit: 2_049

    query =
      if step_id, do: from(command in query, where: command.run_step_id == ^step_id), else: query

    rows = Repo.all(query)
    if length(rows) > 2_048, do: Repo.rollback(:reservation_ledger_too_large)

    Enum.reduce(rows, zero_amounts(), fn {status, arguments, output}, total ->
      amounts =
        status
        |> ledger_row_amounts!(arguments || %{}, output)
        |> validate_ledger_amounts!()

      Enum.reduce(@dimensions, total, fn dimension, acc ->
        atom = String.to_existing_atom(dimension)
        Map.update!(acc, atom, &safe_add!(&1, Map.fetch!(amounts, dimension)))
      end)
    end)
  end

  defp ledger_row_amounts!("claimed", arguments, _output),
    do: Map.fetch!(arguments, "estimate")

  defp ledger_row_amounts!(status, _arguments, output)
       when status in ["completed", "failed", "uncertain"] do
    case Jason.decode(output || "") do
      {:ok, %{"actual" => actual}} when is_map(actual) -> actual
      _error -> Repo.rollback(:invalid_reservation_ledger)
    end
  end

  defp validate_ledger_amounts!(amounts) when is_map(amounts) do
    valid? =
      Enum.all?(@dimensions, fn dimension ->
        Map.has_key?(amounts, dimension) and valid_counter?(Map.get(amounts, dimension))
      end)

    if valid?, do: amounts, else: Repo.rollback(:invalid_reservation_ledger)
  end

  defp validate_ledger_amounts!(_amounts), do: Repo.rollback(:invalid_reservation_ledger)

  defp step_caps(step) do
    params = step.params || %{}

    %{
      requests:
        Map.get(
          params,
          "max_search_calls",
          Map.get(params, "max_requests", Map.get(params, "max_queries", 1))
        ),
      input_tokens: Map.get(params, "max_input_tokens", 0),
      output_tokens: Map.get(params, "max_output_tokens", 0),
      cost_cents: Map.get(params, "max_cost_cents", 0)
    }
    |> validate_caps!()
  end

  defp validate_caps!(caps) do
    if Enum.all?(caps, fn {_key, value} -> valid_counter?(value) end),
      do: caps,
      else: Repo.rollback(:invalid_step_budget_contract)
  end

  defp assert_dimension!(dimension, reserved, requested, cap) do
    if safe_add!(reserved, requested) > cap,
      do: Repo.rollback({:step_budget_exhausted, dimension}),
      else: :ok
  end

  defp assert_optional_budget!(_dimension, used, reserved, requested, nil) do
    _total = safe_add!(safe_add!(used, reserved), requested)
    :ok
  end

  defp assert_optional_budget!(dimension, used, reserved, requested, limit)
       when is_integer(limit) and limit >= 0 do
    total = safe_add!(safe_add!(used, reserved), requested)
    if total > limit, do: Repo.rollback({:run_budget_exhausted, dimension}), else: :ok
  end

  defp assert_optional_budget!(_dimension, _used, _reserved, _requested, _limit),
    do: Repo.rollback(:invalid_run_budget)

  defp assert_within_reservation!(actual, estimate) do
    valid? =
      actual.requests == Map.fetch!(estimate, "requests") and
        Enum.all?(~w(input_tokens output_tokens cost_cents), fn dimension ->
          atom = String.to_existing_atom(dimension)
          Map.fetch!(actual, atom) <= Map.fetch!(estimate, dimension)
        end)

    if valid? do
      :ok
    else
      Repo.rollback(:reservation_overrun)
    end
  end

  defp apply_actual!(run, actual) do
    input = safe_add!(run.input_tokens || 0, actual.input_tokens)
    output = safe_add!(run.output_tokens || 0, actual.output_tokens)
    cost = safe_add!(run.cost_cents || 0, actual.cost_cents)

    total_tokens = safe_add!(input, output)

    if is_integer(run.token_budget) and total_tokens > run.token_budget,
      do: Repo.rollback(:token_budget_invariant)

    if is_integer(run.cost_budget_cents) and cost > run.cost_budget_cents,
      do: Repo.rollback(:cost_budget_invariant)

    run
    |> Run.changeset(%{input_tokens: input, output_tokens: output, cost_cents: cost})
    |> update!()
  end

  defp assert_reservation_authority!(arguments, owner, run_generation, step_generation) do
    valid? =
      arguments["version"] == 1 and arguments["run_generation"] == run_generation and
        arguments["step_generation"] == step_generation and
        secure_owner?(arguments["authority_hash"], owner)

    if valid?, do: :ok, else: Repo.rollback(:reservation_authority_lost)
  end

  defp assert_reservation_lineage!(reservation, arguments, run_generation) do
    run = Repo.get!(Run, reservation.run_id)
    attempt = Repo.get(RunStepAttempt, arguments["attempt_id"])

    valid? =
      not is_nil(attempt) and reservation.run_step_id == attempt.run_step_id and
        attempt.run_id == run.id and
        run.attempt == arguments["run_attempt"] and attempt.run_attempt == run.attempt and
        run.lease_generation == run_generation and
        attempt.run_lease_generation == run_generation and
        attempt.lease_generation == arguments["step_generation"] and
        run.manifest_hash == attempt.manifest_hash

    if valid?, do: :ok, else: Repo.rollback(:reservation_lineage_lost)
  end

  defp envelope(attempt, owner, estimate) do
    %{
      "version" => 1,
      "attempt_id" => attempt.id,
      "run_attempt" => attempt.run_attempt,
      "run_generation" => attempt.run_lease_generation,
      "step_generation" => attempt.lease_generation,
      "manifest_hash" => attempt.manifest_hash,
      "authority_hash" => owner_hash(owner),
      "estimate" => stringify_amounts(estimate)
    }
  end

  defp reservation_digest!(envelope, run_step_id) do
    digest!(%{
      "estimate" => Map.fetch!(envelope, "estimate"),
      "manifest_hash" => Map.fetch!(envelope, "manifest_hash"),
      "run_attempt" => Map.fetch!(envelope, "run_attempt"),
      "run_generation" => Map.fetch!(envelope, "run_generation"),
      "run_step_id" => run_step_id,
      "version" => Map.fetch!(envelope, "version")
    })
  end

  defp reservation_matches?(reservation, digest) do
    reservation.tool_name == @tool_name and reservation.arguments["semantic_digest"] == digest
  end

  defp settled_matches?(reservation, digest) do
    case Jason.decode(reservation.output || "") do
      {:ok, %{"digest" => ^digest}} -> true
      _error -> false
    end
  end

  defp released_matches?(reservation, digest) do
    case Jason.decode(reservation.output || "") do
      {:ok, %{"digest" => ^digest}} -> true
      _error -> false
    end
  end

  defp settlement_receipt(reservation),
    do: %{reservation: reservation, run: Repo.get!(Run, reservation.run_id)}

  defp normalize_amounts(value, opts) do
    allowed = MapSet.new(@dimensions)

    normalized_keys =
      Map.keys(value)
      |> Enum.map(fn key -> if is_atom(key), do: Atom.to_string(key), else: key end)

    cond do
      Enum.any?(normalized_keys, &(not is_binary(&1) or not MapSet.member?(allowed, &1))) ->
        {:error, :invalid_reservation_fields}

      true ->
        amounts =
          Map.new(@dimensions, fn dimension ->
            atom = String.to_existing_atom(dimension)
            {atom, Map.get(value, atom, Map.get(value, dimension, 0))}
          end)

        if Enum.all?(amounts, fn {_key, amount} -> valid_counter?(amount) end) and
             (not opts[:require_request?] or amounts.requests > 0) do
          {:ok, amounts}
        else
          {:error, :invalid_reservation_amount}
        end
    end
  end

  defp normalize_outcome(nil), do: {:ok, "completed"}
  defp normalize_outcome(value) when value in [:completed, "completed"], do: {:ok, "completed"}
  defp normalize_outcome(value) when value in [:failed, "failed"], do: {:ok, "failed"}
  defp normalize_outcome(value) when value in [:uncertain, "uncertain"], do: {:ok, "uncertain"}
  defp normalize_outcome(_value), do: {:error, :invalid_settlement_outcome}

  defp normalize_receipt(receipt) when is_map(receipt) and not is_struct(receipt) do
    case DagPayload.validate(receipt, max_bytes: @max_receipt_bytes) do
      {:ok, validated} -> {:ok, validated}
      {:error, _reason} -> {:error, :invalid_settlement_receipt}
    end
  end

  defp normalize_receipt(nil), do: {:ok, nil}
  defp normalize_receipt(_receipt), do: {:error, :invalid_settlement_receipt}

  defp normalize_payload(nil), do: {:ok, nil, nil}

  defp normalize_payload(payload) when is_map(payload) and not is_struct(payload) do
    with {:ok, payload} <- DagPayload.validate(payload, max_bytes: @max_payload_bytes),
         {:ok, digest} <- DagPayload.digest(payload) do
      {:ok, payload, digest}
    else
      {:error, _reason} -> {:error, :invalid_settlement_payload}
    end
  end

  defp normalize_payload(_payload), do: {:error, :invalid_settlement_payload}

  defp maybe_put_receipt(output, nil), do: output
  defp maybe_put_receipt(output, receipt), do: Map.put(output, "receipt", receipt)

  defp maybe_put_payload(output, nil, nil), do: output

  defp maybe_put_payload(output, payload, payload_digest) do
    output
    |> Map.put("payload", payload)
    |> Map.put("payload_digest", payload_digest)
  end

  defp charged_amounts(_actual, arguments, "uncertain") do
    estimate = Map.fetch!(arguments, "estimate")

    Map.new(@dimensions, fn dimension ->
      {String.to_existing_atom(dimension), Map.fetch!(estimate, dimension)}
    end)
  end

  defp charged_amounts(actual, _arguments, _outcome), do: actual

  defp settlement_error_message("completed"), do: nil
  defp settlement_error_message("failed"), do: "provider_request_failed"
  defp settlement_error_message("uncertain"), do: "provider_usage_uncertain"

  defp settlement_error_details("completed"), do: nil
  defp settlement_error_details("failed"), do: %{"code" => "provider_request_failed"}
  defp settlement_error_details("uncertain"), do: %{"code" => "provider_usage_uncertain"}

  defp settlement_status("completed"), do: "completed"
  defp settlement_status("failed"), do: "failed"
  defp settlement_status("uncertain"), do: "uncertain"

  defp validate_idempotency_key(key) do
    if byte_size(key) in 1..@max_idempotency_bytes and String.valid?(key) and
         not String.match?(key, ~r/\s/) do
      :ok
    else
      {:error, :invalid_reservation_idempotency_key}
    end
  end

  defp valid_counter?(value), do: is_integer(value) and value >= 0 and value <= @max_counter

  defp safe_add!(left, right) when is_integer(left) and is_integer(right) do
    value = left + right
    if valid_counter?(value), do: value, else: Repo.rollback(:budget_counter_overflow)
  end

  defp stringify_amounts(amounts),
    do: Map.new(amounts, fn {key, value} -> {Atom.to_string(key), value} end)

  defp zero_amounts, do: %{requests: 0, input_tokens: 0, output_tokens: 0, cost_cents: 0}

  defp digest!(value) do
    case DagPayload.digest(value) do
      {:ok, digest} -> digest
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp load_attempt!(%RunStepAttempt{id: id}), do: Repo.get!(RunStepAttempt, id)
  defp load_attempt!(id) when is_binary(id), do: Repo.get!(RunStepAttempt, id)
  defp load_reservation!(%RunCommand{id: id}), do: Repo.get!(RunCommand, id)
  defp load_reservation!(id) when is_binary(id), do: Repo.get!(RunCommand, id)

  defp live_timestamp?(%DateTime{} = expiry, timestamp),
    do: DateTime.compare(expiry, timestamp) == :gt

  defp live_timestamp?(_expiry, _timestamp), do: false
  defp owner_hash(owner), do: :crypto.hash(:sha256, owner) |> Base.encode16(case: :lower)

  defp secure_owner?(stored_hash, owner) when is_binary(stored_hash) do
    presented = owner_hash(owner)

    byte_size(stored_hash) == byte_size(presented) and
      Plug.Crypto.secure_compare(stored_hash, presented)
  end

  defp secure_owner?(_stored, _owner), do: false
  defp now_second, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp transaction(fun) do
    case Repo.retry_on_busy(fn -> Repo.transaction(fun, mode: :immediate) end) do
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, reason}
    end
  end

  defp insert!(changeset) do
    case Repo.insert(changeset) do
      {:ok, value} -> value
      {:error, error} -> Repo.rollback(error)
    end
  end

  defp update!(changeset) do
    case Repo.update(changeset) do
      {:ok, value} -> value
      {:error, error} -> Repo.rollback(error)
    end
  end
end
