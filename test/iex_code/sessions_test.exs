defmodule IexCode.SessionsTest do
  use IexCode.DataCase, async: false
  alias IexCode.{Projects, Runs, Sessions, Settings}

  test "creates projects, sessions, messages, and operations" do
    {:ok, project} =
      Projects.create_project(%{name: "Test Project", root_path: "/tmp/test_project"})

    assert project.name == "Test Project"

    {:ok, session} =
      Sessions.create_session(%{
        project_id: project.id,
        title: "Test Session",
        swarm_mode: true
      })

    assert session.swarm_mode == true

    {:ok, msg} =
      Sessions.create_message(%{
        session_id: session.id,
        role: "user",
        content: "Build an API"
      })

    assert msg.content == "Build an API"

    {:ok, op} =
      Sessions.create_operation(%{
        session_id: session.id,
        agent_name: "CoderAgent",
        op_type: "write_file",
        title: "Writing lib/api.ex",
        status: "running",
        progress: 50
      })

    assert op.progress == 50

    ops = Sessions.list_operations(session.id)
    assert length(ops) == 1
  end

  test "message idempotency is atomic under concurrent identical requests" do
    {:ok, project} =
      Projects.create_project(%{
        name: "Message idempotency",
        root_path: "/tmp/message_idempotency"
      })

    {:ok, session} =
      Sessions.create_session(%{project_id: project.id, title: "Idempotent messages"})

    key = "message-once:#{Ecto.UUID.generate()}"

    attrs = %{
      session_id: session.id,
      role: "user",
      agent_name: "User (Durable Run)",
      content: "One durable submission",
      metadata: %{"run_id" => Ecto.UUID.generate()}
    }

    results =
      1..20
      |> Task.async_stream(fn _index -> Sessions.create_message_once(attrs, key) end,
        max_concurrency: 20,
        ordered: false,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(
             results,
             &match?({:ok, _message, disposition} when disposition in [:created, :existing], &1)
           )

    message_ids = Enum.map(results, fn {:ok, message, _disposition} -> message.id end)
    assert length(Enum.uniq(message_ids)) == 1
    assert Enum.count(results, &match?({:ok, _message, :created}, &1)) == 1
    assert Enum.count(Sessions.list_messages(session.id), &(&1.idempotency_key == key)) == 1

    assert {:error, :message_idempotency_conflict} =
             Sessions.create_message_once(%{attrs | content: "Conflicting reuse"}, key)
  end

  test "durable user identity rejects steering or noncanonical legacy content" do
    {:ok, project} =
      Projects.create_project(%{
        name: "Canonical run turn",
        root_path: "/tmp/canonical_run_turn"
      })

    {:ok, session} =
      Sessions.create_session(%{project_id: project.id, title: "Canonical run message"})

    {:ok, run} =
      Runs.create_run(%{
        project_id: project.id,
        session_id: session.id,
        objective: "Inspect the canonical boundary",
        kind: "coding_agent",
        mode: "single",
        metadata: %{"source" => "legacy_durable_run"}
      })

    assert {:ok, _steering} =
             Sessions.create_message(%{
               session_id: session.id,
               role: "user",
               agent_name: "User (Steer)",
               content: "Steering guidance: inspect only tests",
               metadata: %{"run_id" => run.id, "control_id" => Ecto.UUID.generate()}
             })

    assert {:ok, canonical, :created} = Sessions.ensure_run_user_message(run)
    assert canonical.content == run.objective
    assert canonical.idempotency_key == "run-user:#{run.id}"

    {:ok, other_run} =
      Runs.create_run(%{
        project_id: project.id,
        session_id: session.id,
        objective: "Reject a forged canonical key",
        kind: "coding_agent",
        mode: "single"
      })

    assert {:ok, _forged, :created} =
             Sessions.create_message_once(
               %{
                 session_id: session.id,
                 role: "user",
                 agent_name: "User (Steer)",
                 content: "Steering guidance: forged",
                 metadata: %{"run_id" => other_run.id, "control_id" => Ecto.UUID.generate()}
               },
               "run-user:#{other_run.id}"
             )

    assert {:error, :message_idempotency_conflict} =
             Sessions.ensure_run_user_message(other_run)
  end

  test "a persisted session cannot be reparented to another project" do
    {:ok, project} =
      Projects.create_project(%{name: "Session owner", root_path: "/tmp/session_owner"})

    {:ok, other_project} =
      Projects.create_project(%{name: "Other owner", root_path: "/tmp/other_session_owner"})

    {:ok, session} =
      Sessions.create_session(%{project_id: project.id, title: "Owned session"})

    assert {:error, %Ecto.Changeset{} = changeset} =
             Sessions.update_session(session, %{project_id: other_project.id})

    assert {"cannot be changed after creation", _metadata} = changeset.errors[:project_id]
    assert Sessions.get_session(session.id).project_id == project.id
  end

  test "new sessions inherit current model, temperature, and swarm defaults unless overridden" do
    assert {:ok, _settings} =
             Settings.update_settings(%{
               default_model_provider: "anthropic",
               default_model: "claude-inherited",
               temperature: 0.65,
               default_run_mode: "swarm"
             })

    {:ok, project} =
      Projects.create_project(%{name: "Inherited config", root_path: "/tmp/inherited_config"})

    assert {:ok, inherited} =
             Sessions.create_session(%{project_id: project.id, title: "Inherited"})

    assert inherited.model_provider == "anthropic"
    assert inherited.model_name == "claude-inherited"
    assert inherited.temperature == 0.65
    assert inherited.swarm_mode == true

    assert {:ok, explicit} =
             Sessions.create_session(%{
               project_id: project.id,
               title: "Explicit",
               model_provider: "openai",
               model_name: "gpt-explicit",
               temperature: 0.15,
               swarm_mode: false
             })

    assert explicit.model_provider == "openai"
    assert explicit.model_name == "gpt-explicit"
    assert explicit.temperature == 0.15
    assert explicit.swarm_mode == false
  end

  test "persisted session overrides survive global changes while later sessions inherit new defaults" do
    assert {:ok, first_settings} =
             Settings.update_settings(%{
               default_model_provider: "anthropic",
               default_model: "claude-before-restart",
               temperature: 0.45,
               default_run_mode: "swarm"
             })

    {:ok, project} =
      Projects.create_project(%{name: "Precedence", root_path: "/tmp/session_precedence"})

    assert {:ok, existing} =
             Sessions.create_session(%{project_id: project.id, title: "Existing"})

    assert {:ok, reconfigured} =
             Settings.update_settings(%{
               default_model_provider: "openai",
               default_model: "gpt-after-restart",
               temperature: 0.9,
               default_run_mode: "single"
             })

    # A fresh database read represents the settings resolution performed after
    # a process/application restart; no in-memory settings cache is authoritative.
    assert persisted = Settings.get_settings()
    assert persisted.id == first_settings.id
    assert persisted.lock_version == reconfigured.lock_version
    assert persisted.default_model == "gpt-after-restart"

    existing = Sessions.get_session(existing.id)
    existing_policy = Settings.execution_policy(persisted, existing)
    assert existing_policy["model_provider"] == "anthropic"
    assert existing_policy["model_name"] == "claude-before-restart"
    assert existing_policy["temperature"] == 0.45

    assert {:ok, later} = Sessions.create_session(%{project_id: project.id, title: "Later"})
    assert later.model_provider == "openai"
    assert later.model_name == "gpt-after-restart"
    assert later.temperature == 0.9
    assert later.swarm_mode == false
  end

  test "session model and temperature values are bounded in bytes" do
    {:ok, project} =
      Projects.create_project(%{name: "Bounded session", root_path: "/tmp/bounded_session"})

    assert {:ok, boundary} =
             Sessions.create_session(%{
               project_id: project.id,
               title: "Boundary",
               model_name: String.duplicate("é", 120)
             })

    assert byte_size(boundary.model_name) == 240

    assert {:error, changeset} =
             Sessions.create_session(%{
               project_id: project.id,
               title: "Invalid",
               model_name: String.duplicate("é", 121),
               temperature: 2.1
             })

    assert changeset.errors[:model_name]
    assert changeset.errors[:temperature]
  end

  test "usage history and totals contain only observed message usage and may be session scoped" do
    {:ok, project} =
      Projects.create_project(%{name: "Usage", root_path: "/tmp/truthful_usage"})

    {:ok, first} = Sessions.create_session(%{project_id: project.id, title: "First"})
    {:ok, second} = Sessions.create_session(%{project_id: project.id, title: "Second"})

    assert Sessions.list_usage_history(10, session_id: first.id) == []
    assert {:ok, []} = Sessions.fetch_usage_history(10, session_id: first.id)
    assert Sessions.session_usage_totals(first.id).tokens == 0
    assert Sessions.session_usage_totals(first.id).requests == 0

    assert {:ok, %{tokens: 0, requests: 0}} =
             Sessions.fetch_usage_totals(session_id: first.id)

    assert {:error, :invalid_arguments} = Sessions.fetch_usage_history(0, [])
    assert {:error, :invalid_arguments} = Sessions.fetch_usage_totals(:invalid)

    assert {:ok, _message} =
             Sessions.create_message(%{
               session_id: first.id,
               role: "assistant",
               content: "Observed",
               input_tokens: 120,
               output_tokens: 30,
               cost_cents: 4
             })

    assert {:ok, _message} =
             Sessions.create_message(%{
               session_id: second.id,
               role: "assistant",
               content: "Other",
               input_tokens: 10,
               output_tokens: 5,
               cost_cents: 1
             })

    assert [%{tokens: 150, input_tokens: 120, output_tokens: 30, cost_cents: 4}] =
             Sessions.list_usage_history(10, session_id: first.id)

    assert {:ok, [%{tokens: 150}]} =
             Sessions.fetch_usage_history(10, session_id: first.id)

    assert %{
             tokens: 150,
             input_tokens: 120,
             output_tokens: 30,
             cost_cents: 4,
             requests: 1
           } = Sessions.session_usage_totals(first.id)
  end
end
