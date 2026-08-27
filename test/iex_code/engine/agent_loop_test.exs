defmodule IexCode.Engine.AgentLoopTest do
  use IexCode.DataCase, async: false

  alias IexCode.Engine.AgentLoop
  alias IexCode.Execution.Router
  alias IexCode.{Projects, Runs, Sessions, Settings}
  alias IexCode.Runs.Executor

  setup do
    root = Path.join(System.tmp_dir!(), "iex-agent-loop-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    {:ok, project} = Projects.create_project(%{name: "Agent loop", root_path: root})

    {:ok, session} =
      Sessions.create_session(%{
        project_id: project.id,
        title: "Agent loop",
        model_provider: "openai",
        model_name: "live-model",
        temperature: 0.2
      })

    Process.put(:agent_loop_receiver, self())
    Process.put(:agent_loop_tool_result, {:ok, "tool output"})

    on_exit(fn -> File.rm_rf(root) end)

    %{project: project, session: session, root: root}
  end

  test "runs model to tool to model with fenced usage, commands, and messages", context do
    run =
      running_run(context,
        execution_policy: %{
          "agent_max_turns" => 3,
          "allowed_tools" => ["read_file"],
          "model_provider" => "anthropic",
          "model_name" => "snapshotted-model",
          "temperature" => 0.6
        }
      )

    Process.put(:agent_loop_responses, [
      {:ok,
       %{
         text: "I will inspect the file.",
         tool_calls: [%{id: "call-1", name: "read_file", args: %{"path" => "mix.exs"}}],
         usage: %{input_tokens: 2, output_tokens: 3, cost_cents: 1}
       }},
      {:ok,
       %{
         text: "Inspection complete.",
         tool_calls: [],
         usage: %{input_tokens: 4, output_tokens: 5, cost_cents: 2}
       }}
    ])

    assert {:ok, result} = execute(run, context.root)
    assert result.turns == 2
    assert result.tool_calls == 1
    assert result.usage == %{input_tokens: 6, output_tokens: 8, cost_cents: 3}

    assert_receive {:agent_loop_llm_call, _first_messages, _system,
                    %{provider: "anthropic", model: "snapshotted-model", temperature: 0.6}}

    assert_receive {:agent_loop_tool_call, "read_file", trusted_arguments, root}
    assert root == context.root
    assert trusted_arguments["project_id"] == context.project.id
    assert trusted_arguments["session_id"] == context.session.id
    assert trusted_arguments["run_id"] == run.id

    assert_receive {:agent_loop_llm_call, second_messages, _system, _policy}
    assert Enum.any?(second_messages, &(&1.role == "assistant" and &1.tool_calls != []))
    assert Enum.any?(second_messages, &(&1.role == "tool" and &1.content == "tool output"))

    assert [command] = tool_commands(run)
    assert command.idempotency_key == "agent-loop:1:turn:1:call:1"
    assert command.status == "completed"
    assert command.arguments == %{"path" => "mix.exs"}
    assert command.output == "tool output"

    persisted = Runs.get_run!(run.id)
    assert persisted.input_tokens == 6
    assert persisted.output_tokens == 8
    assert persisted.cost_cents == 3

    messages = Sessions.list_messages(context.session.id)
    assert Enum.count(messages, &(&1.role == "user" and &1.metadata["run_id"] == run.id)) == 1

    assert %{
             role: "assistant",
             content: "Inspection complete.",
             input_tokens: 6,
             output_tokens: 8,
             cost_cents: 3
           } = Enum.find(messages, &(&1.role == "assistant" and &1.metadata["run_id"] == run.id))
  end

  test "enforces the bounded turn limit after durable tool settlement", context do
    run = running_run(context, execution_policy: %{"agent_max_turns" => 2})

    Process.put(:agent_loop_responses, [
      tool_response("call-1", 1),
      tool_response("call-2", 2)
    ])

    assert {:error, {:agent_turn_limit_exceeded, 2}} = execute(run, context.root)
    assert Enum.map(tool_commands(run), & &1.status) == ["completed", "completed"]

    refute Enum.any?(Sessions.list_messages(context.session.id), fn message ->
             (message.role == "assistant" and message.metadata) &&
               message.metadata["run_id"] == run.id
           end)
  end

  test "persists failed tools and feeds the bounded failure into the next model turn", context do
    run = running_run(context, execution_policy: %{"allowed_tools" => ["read_file"]})
    Process.put(:agent_loop_tool_result, {:error, :read_failed})

    Process.put(:agent_loop_responses, [
      tool_response("failed-call", 1),
      {:ok, %{text: "The read failed; no change was made.", tool_calls: [], usage: %{}}}
    ])

    assert {:ok, %{content: "The read failed; no change was made."}} = execute(run, context.root)
    assert [%{status: "failed", error_message: error}] = tool_commands(run)
    assert error =~ "read_failed"

    assert_receive {:agent_loop_llm_call, _first, _system, _policy}
    assert_receive {:agent_loop_tool_call, "read_file", _arguments, _root}
    assert_receive {:agent_loop_llm_call, second, _system, _policy}
    assert Enum.any?(second, &(&1.role == "tool" and String.contains?(&1.content, "read_failed")))
  end

  test "reuses a completed tool receipt but refuses an ambiguous later model effect", context do
    run = running_run(context)

    Process.put(:agent_loop_responses, [
      tool_response("first", 1),
      {:error, :provider_temporarily_unavailable}
    ])

    assert {:error, :provider_temporarily_unavailable} = execute(run, context.root)
    assert_receive {:agent_loop_tool_call, "read_file", _arguments, _root}

    Process.put(:agent_loop_responses, [
      tool_response("second-id", 1),
      {:ok, %{text: "Replay complete", tool_calls: [], usage: %{}}}
    ])

    assert {:error, {:model_turn_effect_requires_review, "running"}} =
             execute(run, context.root)

    refute_receive {:agent_loop_tool_call, "read_file", _arguments, _root}
    assert length(tool_commands(run)) == 1

    messages = Sessions.list_messages(context.session.id)
    assert Enum.count(messages, &(&1.role == "user" and &1.metadata["run_id"] == run.id)) == 1
  end

  test "replays a durable final receipt without repeating provider usage", context do
    run = running_run(context)

    Process.put(:agent_loop_responses, [
      {:ok,
       %{
         text: "Persisted completion",
         tool_calls: [],
         usage: %{input_tokens: 7, output_tokens: 11, cost_cents: 2}
       }}
    ])

    assert {:ok, first} = execute(run, context.root)
    assert first.content == "Persisted completion"
    assert_receive {:agent_loop_llm_call, _messages, _system, _policy}

    Process.put(:agent_loop_responses, [
      {:ok, %{text: "must not run", tool_calls: [], usage: %{input_tokens: 100}}}
    ])

    assert {:ok, replay} = execute(run, context.root)
    assert replay.message_id == first.message_id
    assert replay.content == "Persisted completion"
    assert replay.usage == %{input_tokens: 7, output_tokens: 11, cost_cents: 2}
    assert replay.replayed?
    refute_receive {:agent_loop_llm_call, _messages, _system, _policy}

    persisted = Runs.get_run!(run.id)
    assert persisted.input_tokens == 7
    assert persisted.output_tokens == 11
    assert persisted.cost_cents == 2

    assert Enum.count(Sessions.list_messages(context.session.id), fn message ->
             (message.role == "assistant" and message.metadata) &&
               message.metadata["run_id"] == run.id
           end) == 1
  end

  test "initial model history is queried with bounded count and content", context do
    for index <- 1..30 do
      assert {:ok, _message} =
               Sessions.create_message(%{
                 session_id: context.session.id,
                 role: if(rem(index, 2) == 0, do: "assistant", else: "user"),
                 content: "history-#{index}:" <> String.duplicate("x", 30_000)
               })
    end

    run = running_run(context)

    Process.put(:agent_loop_responses, [
      {:ok, %{text: "Bounded history complete", tool_calls: [], usage: %{}}}
    ])

    assert {:ok, _result} = execute(run, context.root)
    assert_receive {:agent_loop_llm_call, messages, _system, _policy}

    # 20 historical rows plus the current objective; every historical content
    # body was truncated in SQL before it reached the agent process.
    assert length(messages) <= 21

    assert Enum.all?(Enum.drop(messages, -1), fn message ->
             String.length(message.content) <= 20_000
           end)
  end

  test "normalizes an OpenAI function-shaped tool call through the real loop", context do
    run = running_run(context, execution_policy: %{"allowed_tools" => ["read_file"]})

    Process.put(:agent_loop_responses, [
      {:ok,
       %{
         "text" => "Inspecting",
         "tool_calls" => [
           %{
             "id" => "function-call-1",
             "function" => %{
               "name" => "read_file",
               "arguments" => Jason.encode!(%{"path" => "mix.exs"})
             }
           }
         ],
         "usage" => %{}
       }},
      {:ok, %{text: "Function call complete", tool_calls: [], usage: %{}}}
    ])

    assert {:ok, %{content: "Function call complete"}} = execute(run, context.root)
    assert_receive {:agent_loop_tool_call, "read_file", %{"path" => "mix.exs"}, _root}

    assert_receive {:agent_loop_llm_call, _first, _system, _policy}
    assert_receive {:agent_loop_llm_call, second, _system, _policy}

    assert Enum.any?(second, fn
             %{role: "tool", tool_call_id: "function-call-1"} -> true
             _message -> false
           end)
  end

  test "provider usage exhausts the run budget before tools can execute", context do
    run = running_run(context, token_budget: 1)

    Process.put(:agent_loop_responses, [
      {:ok,
       %{
         text: "should not persist",
         tool_calls: [%{id: "never", name: "read_file", args: %{"path" => "mix.exs"}}],
         usage: %{input_tokens: 2}
       }}
    ])

    assert {:error, {:token_budget_exhausted, failed}} = execute(run, context.root)
    assert failed.status == "failed"
    assert [%{tool_name: "__llm_chat__", status: "running"}] = Runs.list_commands(run)
    refute_receive {:agent_loop_tool_call, _name, _arguments, _root}
  end

  test "cancellation intent prevents the first provider effect", context do
    run = running_run(context)
    assert {:ok, _requested} = Runs.request_cancellation(run)

    assert {:error, :cancelled} = execute(run, context.root)
    refute_receive {:agent_loop_llm_call, _messages, _system, _policy}
    assert Runs.list_commands(run) == []
  end

  test "provider cancellation callback detects lease expiry during a turn", context do
    run = running_run(context)

    Process.put(:agent_loop_probe_cancelled?, true)

    Process.put(:agent_loop_before_chat, fn ->
      run
      |> Ecto.Changeset.change(
        lease_expires_at:
          DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.truncate(:second)
      )
      |> IexCode.Repo.update!()
    end)

    Process.put(:agent_loop_responses, [
      {:ok, %{text: "stale response", tool_calls: [], usage: %{output_tokens: 1}}}
    ])

    assert {:error, :lease_not_owned} = execute(run, context.root)
    assert_receive {:agent_loop_cancelled_probe, true}
  end

  test "cancellation after a native effect leaves an ambiguous command unreplayable", context do
    run = running_run(context, execution_policy: %{"allowed_tools" => ["read_file"]})

    Process.put(:agent_loop_tool_result, fn _name, arguments, _root ->
      assert arguments["run_id"] == run.id
      assert {:ok, _requested} = Runs.request_cancellation(run.id)
      {:ok, "effect may already have happened"}
    end)

    Process.put(:agent_loop_responses, [tool_response("cancel-after-effect", 1)])

    assert {:error, :cancelled} = execute(run, context.root)
    assert [%{status: "running"}] = tool_commands(run)

    authority = authority_opts(run)
    assert {:ok, cancelled} = Runs.finalize_run_worker(run, "cancelled", %{}, authority)
    assert {:error, :command_effect_requires_review} = Runs.retry_run(cancelled)
  end

  test "production executor routes legacy single coding runs through the agent loop", context do
    run = running_run(context)

    Process.put(:agent_loop_responses, [
      {:ok, %{text: "Executor single-agent complete", tool_calls: [], usage: %{output_tokens: 2}}}
    ])

    assert {:ok, %{content: "Executor single-agent complete", turns: 1}} =
             Executor.execute(run, fn _percent, _message -> :ok end,
               llm: IexCode.AgentLoopLLMStub,
               tool_executor: IexCode.AgentLoopToolStub,
               run_lease_owner: run.lease_owner,
               run_attempt: run.attempt,
               run_lease_generation: run.lease_generation,
               run_terminal_lease_ms: 30_000
             )
  end

  test "router-enqueued 240-byte model reaches the production single-agent executor", context do
    model = String.duplicate("m", 240)

    assert {:ok, %{run: queued}} =
             Router.route("/run execute the bounded model", %{
               project_id: context.project.id,
               session_id: context.session.id,
               settings: Settings.get_settings(),
               overrides: %{model_name: model},
               request_key: "agent-loop-model-boundary-#{Ecto.UUID.generate()}"
             })

    assert queued.metadata["execution_policy"]["model_name"] == model

    owner = "agent-loop-router:#{System.unique_integer([:positive])}"
    assert {:ok, run} = Runs.claim_next_run(owner, lease_ms: 300_000)
    assert run.id == queued.id

    Process.put(:agent_loop_responses, [
      {:ok, %{text: "Boundary model complete", tool_calls: [], usage: %{}}}
    ])

    assert {:ok, %{content: "Boundary model complete"}} = execute(run, context.root)

    assert_receive {:agent_loop_llm_call, _messages, _system,
                    %{provider: "openai", model: ^model}}
  end

  test "queued single-agent run rejects endpoint drift before its first model effect", context do
    settings = Settings.get_settings()
    policy = Settings.execution_policy(settings, context.session)
    run = running_run(context, execution_policy: policy)

    assert {:ok, _updated} =
             Settings.update_settings(%{openai_base_url: "https://changed.example/v1"})

    Process.put(:agent_loop_responses, [
      {:ok, %{text: "must not execute", tool_calls: [], usage: %{}}}
    ])

    assert {:error, :model_route_configuration_changed} = execute(run, context.root)
    refute_receive {:agent_loop_llm_call, _messages, _system, _policy}
    assert [%{status: "queued", tool_name: "__llm_chat__"}] = Runs.list_commands(run)
  end

  test "in-progress single-agent run rejects endpoint drift before its next model turn",
       context do
    settings = Settings.get_settings()
    policy = Settings.execution_policy(settings, context.session)
    run = running_run(context, execution_policy: policy)

    Process.put(:agent_loop_before_chat, fn ->
      Process.delete(:agent_loop_before_chat)

      assert {:ok, _updated} =
               Settings.update_settings(%{openai_base_url: "https://changed-mid-run.example/v1"})
    end)

    Process.put(:agent_loop_responses, [tool_response("drift-call", 1)])

    assert {:error, :model_route_configuration_changed} = execute(run, context.root)
    assert_receive {:agent_loop_llm_call, _messages, _system, _policy}
    refute_receive {:agent_loop_llm_call, _messages, _system, _policy}

    assert Runs.list_commands(run)
           |> Enum.map(&{&1.tool_name, &1.status})
           |> Enum.sort() ==
             Enum.sort([
               {"__llm_chat__", "completed"},
               {"read_file", "completed"},
               {"__llm_chat__", "queued"}
             ])
  end

  test "durable steering is marked consumed only when appended to a model turn", context do
    run = running_run(context)

    assert {:ok, pending} =
             Runs.enqueue_control(run, "agent-loop-steer", %{
               kind: "steer",
               payload: %{"guidance" => "Inspect only the configuration layer"}
             })

    assert {:ok, claimed} = Runs.claim_control(pending, run.lease_owner)

    Process.put(:agent_loop_responses, [
      {:ok, %{text: "Steering applied", tool_calls: [], usage: %{}}}
    ])

    assert {:ok, _result} = execute(run, context.root)
    assert_receive {:agent_loop_llm_call, messages, _system, _policy}

    assert Enum.any?(messages, fn message ->
             message.role == "user" and
               message.content == "Steering guidance: Inspect only the configuration layer"
           end)

    assert %{status: "applied", result: %{"status" => "consumed", "turn" => 1}} =
             Runs.get_control(claimed.id)
  end

  test "replays the exact consumed guidance after the control was applied before a crash",
       context do
    run = running_run(context)
    guidance = "Keep the completed provider turn's guidance"
    claimed = claimed_steering(run, "agent-loop-applied-crash-steer", guidance)

    persist_completed_steered_model_turn(
      run,
      claimed,
      guidance,
      "Recovered after applied-control crash"
    )

    result = %{"action" => "steer", "status" => "consumed", "turn" => 1}

    assert {:ok, _applied} =
             Runs.resolve_control(claimed, "applied", result,
               run_id: run.id,
               worker_id: run.lease_owner,
               kind: "steer",
               target_attempt: run.attempt,
               target_generation: run.lease_generation,
               claim_generation: run.lease_generation
             )

    # Simulates a worker dying after the model receipt and control resolution,
    # but before it could persist the final assistant message.
    assert {:ok, replayed} = execute(run, context.root)
    assert replayed.content == "Recovered after applied-control crash"
    refute_receive {:agent_loop_llm_call, _messages, _system, _policy}
    assert Runs.get_control(claimed.id).status == "applied"
  end

  test "a completed paid turn reclaims an expired steering claim before resolution", context do
    run = running_run(context)
    guidance = "Guidance whose short claim elapsed during the provider call"
    claimed = claimed_steering(run, "agent-loop-expired-steer", guidance)
    timestamp = DateTime.utc_now() |> DateTime.truncate(:second)

    Process.put(:agent_loop_before_chat, fn ->
      claimed
      |> Ecto.Changeset.change(
        claimed_at: DateTime.add(timestamp, -120, :second),
        claim_expires_at: DateTime.add(timestamp, -60, :second)
      )
      |> IexCode.Repo.update!()
    end)

    Process.put(:agent_loop_responses, [
      {:ok,
       %{
         text: "Long provider turn completed",
         tool_calls: [],
         usage: %{input_tokens: 3, output_tokens: 2}
       }}
    ])

    assert {:ok, replayed} = execute(run, context.root)
    assert replayed.content == "Long provider turn completed"
    assert_receive {:agent_loop_llm_call, messages, _system, _policy}

    assert Enum.any?(messages, fn message ->
             message.role == "user" and
               message.content == "Steering guidance: " <> guidance
           end)

    assert %{status: "applied", claim_expires_at: expires_at} = Runs.get_control(claimed.id)
    assert DateTime.compare(expires_at, timestamp) == :gt
  end

  test "failed provider turns leave claimed steering available for retry", context do
    run = running_run(context)

    assert {:ok, pending} =
             Runs.enqueue_control(run, "agent-loop-failed-steer", %{
               kind: "steer",
               payload: %{"guidance" => "Preserve this guidance"}
             })

    assert {:ok, claimed} = Runs.claim_control(pending, run.lease_owner)
    Process.put(:agent_loop_responses, [{:error, :provider_temporarily_unavailable}])

    assert {:error, :provider_temporarily_unavailable} = execute(run, context.root)
    assert Runs.get_control(claimed.id).status == "claimed"
  end

  test "an ambiguous model turn receipt fails closed without losing claimed steering", context do
    run = running_run(context)
    authority = authority_opts(run)

    assert {:ok, pending} =
             Runs.enqueue_control(run, "agent-loop-ambiguous-steer", %{
               kind: "steer",
               payload: %{"guidance" => "Do not lose this guidance"}
             })

    assert {:ok, claimed} = Runs.claim_control(pending, run.lease_owner)

    assert {:ok, queued} =
             Runs.enqueue_command_worker(
               run,
               "agent-loop:model:1:turn:1",
               %{
                 tool_name: "__llm_chat__",
                 arguments: %{
                   "turn" => 1,
                   "context_sha256" =>
                     payload_sha256([
                       %{role: "user", content: run.objective},
                       %{role: "user", content: "Steering guidance: Do not lose this guidance"}
                     ]),
                   "steering_control_ids" => [claimed.id],
                   "model_provider" => "openai",
                   "model_name" => "live-model",
                   "max_tokens" => nil
                 }
               },
               authority
             )

    assert {:ok, _running} =
             Runs.transition_command_worker(queued, "running", %{attempt: 1}, authority)

    assert {:error, {:model_turn_effect_requires_review, "running"}} =
             execute(run, context.root)

    refute_receive {:agent_loop_llm_call, _messages, _system, _policy}
    assert Runs.get_control(claimed.id).status == "claimed"
  end

  test "retry refuses an ambiguous running native command", context do
    run = running_run(context)
    authority = authority_opts(run)

    assert {:ok, queued} =
             Runs.enqueue_command_worker(
               run,
               "agent-loop-ambiguous",
               %{tool_name: "run_command", arguments: %{"command" => "mix test"}},
               authority
             )

    assert {:ok, _running} =
             Runs.transition_command_worker(queued, "running", %{attempt: 1}, authority)

    assert {:ok, interrupted} =
             Runs.finalize_run_worker(run, "interrupted", %{}, authority)

    assert interrupted.status == "interrupted"
    assert {:error, :command_effect_requires_review} = Runs.retry_run(interrupted)
  end

  test "snapshotted execution policy cannot be changed after creation", context do
    run = running_run(context, execution_policy: %{"agent_max_turns" => 3})

    changed_metadata = put_in(run.metadata["execution_policy"]["agent_max_turns"], 20)

    assert {:error, changeset} =
             run
             |> IexCode.Runs.Run.changeset(%{metadata: changed_metadata})
             |> IexCode.Repo.update()

    assert {"execution policy cannot be changed after creation", _opts} =
             changeset.errors[:metadata]
  end

  defp running_run(context, options \\ []) do
    policy = Keyword.get(options, :execution_policy, %{"agent_max_turns" => 5})

    attrs = %{
      project_id: context.project.id,
      session_id: context.session.id,
      objective: "Inspect the project and report",
      kind: "coding_agent",
      mode: "single",
      token_budget: Keyword.get(options, :token_budget),
      metadata: %{"source" => "agent_loop_test", "execution_policy" => policy}
    }

    {:ok, _queued} = Runs.create_run(attrs)
    owner = "agent-loop-test:#{System.unique_integer([:positive])}"
    {:ok, run} = Runs.claim_next_run(owner, lease_ms: 300_000)
    run
  end

  defp execute(run, root) do
    AgentLoop.execute(run, root, fn _percent, _message -> :ok end,
      llm: IexCode.AgentLoopLLMStub,
      tool_executor: IexCode.AgentLoopToolStub,
      run_lease_owner: run.lease_owner,
      run_attempt: run.attempt,
      run_lease_generation: run.lease_generation,
      run_terminal_lease_ms: 30_000
    )
  end

  defp authority_opts(run) do
    [
      lease_owner: run.lease_owner,
      run_attempt: run.attempt,
      lease_generation: run.lease_generation,
      terminal_lease_ms: 30_000
    ]
  end

  defp tool_response(id, marker) do
    {:ok,
     %{
       text: "tool turn #{marker}",
       tool_calls: [%{id: id, name: "read_file", args: %{"path" => "mix.exs"}}],
       usage: %{}
     }}
  end

  defp tool_commands(run) do
    run
    |> Runs.list_commands()
    |> Enum.reject(&(&1.tool_name == "__llm_chat__"))
  end

  defp claimed_steering(run, key, guidance) do
    assert {:ok, pending} =
             Runs.enqueue_control(run, key, %{
               kind: "steer",
               payload: %{"guidance" => guidance}
             })

    assert {:ok, claimed} = Runs.claim_control(pending, run.lease_owner)
    claimed
  end

  defp persist_completed_steered_model_turn(run, control, guidance, text) do
    arguments = %{
      "turn" => 1,
      "context_sha256" =>
        payload_sha256([
          %{role: "user", content: run.objective},
          %{role: "user", content: "Steering guidance: " <> guidance}
        ]),
      "steering_control_ids" => [control.id],
      "model_provider" => "openai",
      "model_name" => "live-model",
      "max_tokens" => nil
    }

    assert {:ok, queued} =
             Runs.enqueue_command_worker(
               run,
               "agent-loop:model:#{run.attempt}:turn:1",
               %{tool_name: "__llm_chat__", arguments: arguments, max_attempts: 1},
               authority_opts(run)
             )

    assert {:ok, running} =
             Runs.transition_command_worker(
               queued,
               "running",
               %{attempt: queued.attempt + 1},
               authority_opts(run)
             )

    receipt = Jason.encode!(%{"text" => text, "tool_calls" => [], "usage" => %{}})

    assert {:ok, _completed} =
             Runs.transition_command_worker(
               running,
               "completed",
               %{output: receipt},
               authority_opts(run)
             )
  end

  defp payload_sha256(value) do
    value
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
