defmodule IexCode.Research.ProviderEffectTest do
  use IexCode.DataCase, async: false

  import Ecto.Query

  alias IexCode.{Projects, Repo, Sessions}
  alias IexCode.Research.ProviderEffect
  alias IexCode.Runs.{Run, RunCommand, RunStep, RunStepAttempt}

  @owner "provider-effect-owner"
  @manifest_hash String.duplicate("e", 64)
  @estimate %{requests: 1, input_tokens: 10, output_tokens: 5, cost_cents: 4}
  @usage %{requests: 1, input_tokens: 4, output_tokens: 2, cost_cents: 2}

  setup do
    root = Path.join(System.tmp_dir!(), "provider-effect-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    {:ok, project} =
      Projects.create_project(%{
        name: "Provider effect #{System.unique_integer([:positive])}",
        root_path: root
      })

    {:ok, session} =
      Sessions.create_session(%{project_id: project.id, title: "Provider effect boundary"})

    on_exit(fn -> File.rm_rf(root) end)
    %{project: project, session: session}
  end

  test "intent exists before callback and completed usage is charged once", context do
    %{attempt: attempt, run: run} = fixture(context)
    parent = self()

    callback = fn ->
      command = Repo.one!(from command in RunCommand, select: command)
      send(parent, {:callback_saw, command.status})
      {:ok, %{"answer" => "bounded"}, @usage}
    end

    assert {:ok, receipt} = invoke(attempt, "complete", %{"query" => "safe"}, callback)
    assert_receive {:callback_saw, "claimed"}
    assert receipt.status == :completed
    assert receipt.replayed? == false
    assert receipt.response == %{"answer" => "bounded"}
    assert byte_size(receipt.response_digest) == 64

    command = Repo.get!(RunCommand, receipt.reservation.id)
    assert command.status == "completed"

    assert %{
             "actual" => %{
               "requests" => 1,
               "input_tokens" => 4,
               "output_tokens" => 2,
               "cost_cents" => 2
             },
             "receipt" => %{"response_digest" => response_digest}
           } = Jason.decode!(command.output)

    assert response_digest == receipt.response_digest
    assert %{input_tokens: 4, output_tokens: 2, cost_cents: 2} = Repo.get!(Run, run.id)
  end

  test "same semantic call never invokes the provider twice", context do
    %{attempt: attempt} = fixture(context)
    counter = start_supervised!({Agent, fn -> 0 end})

    callback = fn ->
      Agent.update(counter, &(&1 + 1))
      {:ok, %{"answer" => "once"}, @usage}
    end

    assert {:ok, first} = invoke(attempt, "same", %{"query" => "one"}, callback)
    assert {:ok, replay} = invoke(attempt, "same", %{"query" => "one"}, callback)
    assert first.reservation.id == replay.reservation.id
    assert replay.replayed? == true
    assert replay.response == %{"answer" => "once"}
    assert Agent.get(counter, & &1) == 1
  end

  test "completed response replays across a new step attempt without another call", context do
    %{attempt: first_attempt, run: run, step: step} = fixture(context)
    counter = start_supervised!({Agent, fn -> 0 end})

    callback = fn ->
      Agent.update(counter, &(&1 + 1))
      {:ok, %{"answer" => "durable replay"}, @usage}
    end

    assert {:ok, first} =
             invoke(first_attempt, "cross-attempt", %{"query" => "same"}, callback)

    second_attempt = retry_attempt!(run, step, first_attempt)

    assert {:ok, replay} =
             ProviderEffect.invoke(
               second_attempt,
               @owner,
               3,
               2,
               "cross-attempt",
               %{"query" => "same"},
               @estimate,
               callback
             )

    assert replay.replayed?
    assert replay.response == first.response
    assert replay.response_digest == first.response_digest
    assert Agent.get(counter, & &1) == 1
    assert Repo.aggregate(RunCommand, :count) == 1
  end

  test "tampered completed payload fails closed and never invokes callback", context do
    %{attempt: attempt} = fixture(context)
    counter = start_supervised!({Agent, fn -> 0 end})

    assert {:ok, receipt} =
             invoke(attempt, "tamper", %{"query" => "same"}, fn ->
               {:ok, %{"answer" => "original"}, @usage}
             end)

    output = Jason.decode!(receipt.reservation.output)
    tampered = put_in(output, ["payload", "answer"], "tampered") |> Jason.encode!()

    Repo.update_all(from(command in RunCommand, where: command.id == ^receipt.reservation.id),
      set: [output: tampered]
    )

    assert {:error, :invalid_provider_effect_receipt} =
             invoke(attempt, "tamper", %{"query" => "same"}, fn ->
               Agent.update(counter, &(&1 + 1))
             end)

    assert Agent.get(counter, & &1) == 0
  end

  test "tampered payload and settlement digests independently fail replay closed", context do
    for {suffix, mutate} <- [
          {"payload-digest",
           fn output ->
             Map.put(output, "payload_digest", String.duplicate("0", 64))
           end},
          {"settlement-digest",
           fn output ->
             Map.put(output, "digest", String.duplicate("0", 64))
           end}
        ] do
      %{attempt: attempt} = fixture(context, key: suffix)

      counter =
        start_supervised!(%{
          id: {:tamper_counter, suffix},
          start: {Agent, :start_link, [fn -> 0 end]}
        })

      assert {:ok, receipt} =
               invoke(attempt, suffix, %{"query" => "same"}, fn ->
                 {:ok, %{"answer" => suffix}, @usage}
               end)

      tampered = receipt.reservation.output |> Jason.decode!() |> mutate.() |> Jason.encode!()

      Repo.update_all(from(command in RunCommand, where: command.id == ^receipt.reservation.id),
        set: [output: tampered]
      )

      assert {:error, :invalid_provider_effect_receipt} =
               invoke(attempt, suffix, %{"query" => "same"}, fn ->
                 Agent.update(counter, &(&1 + 1))
               end)

      assert Agent.get(counter, & &1) == 0
    end
  end

  test "a concurrent caller observes ambiguity instead of double invoking", context do
    %{attempt: attempt} = fixture(context)
    parent = self()
    counter = start_supervised!({Agent, fn -> 0 end})

    callback = fn ->
      Agent.update(counter, &(&1 + 1))
      send(parent, {:provider_entered, self()})

      receive do
        :return -> {:ok, %{"answer" => "once"}, @usage}
      end
    end

    task =
      Task.Supervisor.async_nolink(IexCode.TaskSupervisor, fn ->
        invoke(attempt, "concurrent", %{"query" => "one"}, callback)
      end)

    assert_receive {:provider_entered, callback_pid}

    assert {:error, :external_effect_ambiguous} =
             invoke(attempt, "concurrent", %{"query" => "one"}, callback)

    send(callback_pid, :return)
    assert {:ok, _receipt} = Task.await(task, 1_000)
    assert Agent.get(counter, & &1) == 1
  end

  test "cancellation and checkpoint rejection before the call release capacity", context do
    %{attempt: attempt} = fixture(context)
    counter = start_supervised!({Agent, fn -> 0 end})
    callback = fn -> Agent.update(counter, &(&1 + 1)) end

    assert {:error, :cancelled} =
             invoke(attempt, "cancelled", %{"query" => "one"}, callback,
               cancelled?: fn -> true end
             )

    assert {:error, :checkpoint_failed} =
             invoke(attempt, "checkpoint", %{"query" => "two"}, callback,
               checkpoint: fn _payload, _progress -> {:error, :stale} end
             )

    assert Agent.get(counter, & &1) == 0

    assert Repo.aggregate(
             from(command in RunCommand, where: command.status == "cancelled"),
             :count,
             :id
           ) == 2
  end

  test "pre-call release failure is surfaced and callback remains unexecuted", context do
    %{attempt: attempt, run: run} = fixture(context)
    counter = start_supervised!({Agent, fn -> 0 end})

    assert {:error, :external_effect_release_failed} =
             invoke(
               attempt,
               "release-failure",
               %{"query" => "one"},
               fn -> Agent.update(counter, &(&1 + 1)) end,
               checkpoint: fn _payload, _progress ->
                 Repo.update_all(from(current in Run, where: current.id == ^run.id),
                   set: [status: "failed"]
                 )

                 {:error, :preflight_rejected}
               end
             )

    assert Agent.get(counter, & &1) == 0
    assert Repo.one!(from command in RunCommand, select: command.status) == "claimed"
  end

  test "timeout is uncertain, redacted, terminal, and charges the full estimate", context do
    %{attempt: attempt, run: run} = fixture(context)

    callback = fn ->
      receive do
        :never -> {:ok, %{"answer" => "late"}, @usage}
      end
    end

    assert {:error, :external_effect_uncertain} =
             invoke(attempt, "timeout", %{"query" => "one"}, callback, timeout_ms: 10)

    command = Repo.one!(from command in RunCommand, select: command)
    assert command.status == "uncertain"
    assert command.error_details == %{"code" => "provider_usage_uncertain"}
    assert %{input_tokens: 10, output_tokens: 5, cost_cents: 4} = Repo.get!(Run, run.id)

    assert {:error, :external_effect_uncertain} =
             invoke(attempt, "timeout", %{"query" => "one"}, fn ->
               flunk("uncertain effect must not replay")
             end)

    assert {:error, :worker_authority_required} =
             IexCode.Runs.transition_command(command, "failed")

    changeset = RunCommand.changeset(command, %{status: "failed"})
    assert "cannot transition from uncertain" in errors_on(changeset).status

    assert_raise Exqlite.Error, ~r/run_command_uncertain_terminal/, fn ->
      Repo.update_all(from(current in RunCommand, where: current.id == ^command.id),
        set: [status: "failed"]
      )
    end
  end

  test "cancellation after the callback starts settles uncertain", context do
    %{attempt: attempt, run: run} = fixture(context)
    parent = self()
    cancelled = start_supervised!({Agent, fn -> false end})

    task =
      Task.Supervisor.async_nolink(IexCode.TaskSupervisor, fn ->
        invoke(
          attempt,
          "cancel-after-start",
          %{"query" => "one"},
          fn ->
            send(parent, :callback_started)

            receive do
              :never -> {:ok, %{"answer" => "late"}, @usage}
            end
          end,
          cancelled?: fn -> Agent.get(cancelled, & &1) end,
          timeout_ms: 1_000
        )
      end)

    assert_receive :callback_started
    Agent.update(cancelled, fn _ -> true end)
    assert {:error, :external_effect_uncertain} = Task.await(task, 1_000)

    command = Repo.one!(from command in RunCommand, select: command)
    assert command.status == "uncertain"
    assert %{input_tokens: 10, output_tokens: 5, cost_cents: 4} = Repo.get!(Run, run.id)
  end

  test "raise, exit, throw, and malformed returns settle as uncertain without leaking", context do
    for {operation, callback} <- [
          {"raise", fn -> raise "sentinel-raise-secret" end},
          {"exit", fn -> exit(:sentinel_exit_secret) end},
          {"throw", fn -> throw(:sentinel_throw_secret) end},
          {"shape", fn -> {:ok, "wrong"} end}
        ] do
      %{attempt: attempt} = fixture(context, key: operation)

      assert {:error, :external_effect_uncertain} =
               invoke(attempt, operation, %{"query" => operation}, callback)
    end

    persisted =
      Repo.all(from command in RunCommand, select: {command.output, command.error_message})
      |> inspect()

    refute persisted =~ "sentinel"

    assert Repo.aggregate(
             from(command in RunCommand, where: command.status == "uncertain"),
             :count,
             :id
           ) == 4
  end

  test "explicit provider failure settles trustworthy actual usage", context do
    %{attempt: attempt, run: run} = fixture(context)

    assert {:error, :rate_limited} =
             invoke(attempt, "failure", %{"query" => "one"}, fn ->
               {:error, :rate_limited, @usage}
             end)

    command = Repo.one!(from command in RunCommand, select: command)
    assert command.status == "failed"
    assert %{input_tokens: 4, output_tokens: 2, cost_cents: 2} = Repo.get!(Run, run.id)
  end

  test "secret requests fail before reservation and secret or oversized responses are uncertain",
       context do
    %{attempt: attempt} = fixture(context)

    assert {:error, :provider_request_contains_secret} =
             invoke(attempt, "secret-request", %{"authorization" => "sentinel"}, fn ->
               flunk("request validation must precede callback")
             end)

    assert Repo.aggregate(RunCommand, :count) == 0

    assert {:error, :invalid_provider_effect_options} =
             invoke(
               attempt,
               "caller-widening",
               %{"query" => "safe"},
               fn -> flunk("invalid ceiling must precede callback") end,
               max_response_bytes: 256_001
             )

    assert Repo.aggregate(RunCommand, :count) == 0

    assert {:error, :external_effect_uncertain} =
             invoke(attempt, "secret-response", %{"query" => "safe"}, fn ->
               {:ok, %{"nested" => %{"access_token" => "sentinel"}}, @usage}
             end)

    %{attempt: second_attempt} = fixture(context, key: "oversized")

    assert {:error, :external_effect_uncertain} =
             invoke(
               second_attempt,
               "oversized-response",
               %{"query" => "safe"},
               fn -> {:ok, %{"answer" => String.duplicate("x", 256_001)}, @usage} end
             )

    persisted = Repo.all(from command in RunCommand, select: command.output) |> inspect()
    refute persisted =~ "sentinel"
    refute persisted =~ String.duplicate("x", 50)

    assert Repo.aggregate(
             from(command in RunCommand, where: command.status == "uncertain"),
             :count,
             :id
           ) == 2
  end

  test "authority failures happen before callback execution", context do
    %{attempt: attempt} = fixture(context)
    counter = start_supervised!({Agent, fn -> 0 end})
    callback = fn -> Agent.update(counter, &(&1 + 1)) end

    assert {:error, :run_lease_lost} =
             ProviderEffect.invoke(
               attempt,
               "foreign",
               3,
               1,
               "foreign",
               %{"query" => "one"},
               @estimate,
               callback
             )

    assert {:error, :run_lease_lost} =
             ProviderEffect.invoke(
               attempt,
               @owner,
               4,
               1,
               "stale-run",
               %{"query" => "one"},
               @estimate,
               callback
             )

    assert {:error, :step_lease_lost} =
             ProviderEffect.invoke(
               attempt,
               @owner,
               3,
               2,
               "stale-step",
               %{"query" => "one"},
               @estimate,
               callback
             )

    assert Agent.get(counter, & &1) == 0
  end

  defp invoke(attempt, operation, descriptor, callback, opts \\ []) do
    ProviderEffect.invoke(
      attempt,
      @owner,
      3,
      1,
      operation,
      descriptor,
      @estimate,
      callback,
      opts
    )
  end

  defp fixture(context, opts \\ []) do
    timestamp = DateTime.utc_now() |> DateTime.truncate(:second)
    suffix = Keyword.get(opts, :key, "default-#{System.unique_integer([:positive])}")

    {:ok, run} =
      %Run{project_id: context.project.id, session_id: context.session.id}
      |> Run.create_changeset(%{
        objective: "Provider effect #{suffix}",
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
        token_budget: 100,
        cost_budget_cents: 40
      })
      |> Repo.insert()

    step =
      %RunStep{run_id: run.id}
      |> RunStep.create_changeset(%{
        key: "research.search.grounded.#{suffix}",
        kind: "research_grounded_search",
        title: "Provider effect",
        status: "running",
        attempt: 1,
        max_attempts: 2,
        params: %{
          "max_search_calls" => 4,
          "max_input_tokens" => 40,
          "max_output_tokens" => 20,
          "max_cost_cents" => 16
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
        execution_key: "2:#{step.key}:1",
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

  defp retry_attempt!(run, step, first_attempt) do
    timestamp = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.update_all(from(attempt in RunStepAttempt, where: attempt.id == ^first_attempt.id),
      set: [
        status: "interrupted",
        lease_owner: nil,
        lease_expires_at: nil,
        completed_at: timestamp
      ]
    )

    Repo.update_all(from(current in RunStep, where: current.id == ^step.id),
      set: [attempt: 2]
    )

    owner_hash = :crypto.hash(:sha256, @owner) |> Base.encode16(case: :lower)

    %RunStepAttempt{run_id: run.id, run_step_id: step.id}
    |> RunStepAttempt.changeset(%{
      run_attempt: 2,
      run_lease_generation: 3,
      attempt: 2,
      execution_key: "2:#{step.key}:2",
      manifest_hash: @manifest_hash,
      handler_kind: step.kind,
      handler_version: 1,
      effect_class: "provider",
      replay_policy: "never",
      status: "running",
      run_owner: owner_hash,
      claim_owner: owner_hash,
      lease_owner: owner_hash,
      lease_generation: 2,
      lease_expires_at: DateTime.add(timestamp, 30, :second),
      heartbeat_at: timestamp,
      started_at: timestamp
    })
    |> Repo.insert!()
  end
end
