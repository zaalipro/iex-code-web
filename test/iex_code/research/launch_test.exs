defmodule IexCode.Research.LaunchTest do
  use IexCode.DataCase, async: false

  alias IexCode.Research.{Launch, Results}
  alias IexCode.Sessions.Session
  alias IexCode.Settings.AppSettings
  alias IexCode.{Projects, Runs, Sessions, Settings}

  setup do
    root =
      Path.join(System.tmp_dir!(), "research-launch-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    {:ok, project} = Projects.create_project(%{name: "Launch", root_path: root})
    {:ok, session} = Sessions.create_session(%{project_id: project.id, title: "Launch"})

    settings = %AppSettings{
      id: Ecto.UUID.generate(),
      updated_at: DateTime.utc_now(),
      search_provider_order: ["tavily", "duckduckgo"],
      search_providers: %{
        "tavily" => %{
          "enabled" => true,
          "api_key" => "test-key",
          "base_url" => "https://api.tavily.com"
        },
        "duckduckgo" => %{
          "enabled" => true,
          "base_url" => "https://html.duckduckgo.com"
        }
      }
    }

    %{
      project: project,
      session: session,
      settings: settings,
      trusted_settings: Settings.get_settings()
    }
  end

  test "normalizes the exact level contract and validates selected provider readiness", context do
    assert Launch.levels() == ~w(low medium high ultra)
    assert Launch.max_sources() == 40
    assert Launch.ready_ranked_providers(context.settings) == ["tavily", "duckduckgo"]

    assert {:ok, launch} =
             Launch.normalize_request(
               %{
                 level: "ultra",
                 ranked_providers: ["tavily", :duckduckgo, "tavily"],
                 max_sources: 40,
                 fetch_parallelism: 8,
                 require_conflict_audit: false
               },
               settings: context.settings
             )

    assert launch.level == "ultra"
    assert launch.ranked_providers == ["tavily", "duckduckgo"]
    assert launch.max_sources == 40
    assert launch.fetch_parallelism == 8
    refute launch.require_conflict_audit

    disabled = put_in(context.settings.search_providers["tavily"]["enabled"], false)

    assert {:error, {:research_providers_unavailable, [%{provider: "tavily", reason: :disabled}]}} =
             Launch.normalize_request(
               %{level: "low", ranked_providers: ["tavily"]},
               settings: disabled
             )
  end

  test "rejects source limits above the durable finalizer contract" do
    assert {:error, {:research_max_sources_out_of_range, %{minimum: 1, maximum: 40, value: 41}}} =
             Launch.normalize_request(%{
               level: "low",
               ranked_providers: ["duckduckgo"],
               max_sources: 41
             })
  end

  test "canonical enqueue requires trusted current settings and session", context do
    request = %{
      objective: "Require current routing authority",
      level: "low",
      ranked_providers: ["duckduckgo"]
    }

    base = %{
      project_id: context.project.id,
      session_id: context.session.id,
      request_key: Ecto.UUID.generate()
    }

    assert {:error, :settings_unavailable} = Launch.enqueue(base, request)

    assert {:error, :settings_unavailable} =
             Launch.enqueue(Map.put(base, :settings, %AppSettings{}), request)

    assert {:error, :settings_unavailable} =
             Launch.enqueue(
               Map.put(base, :settings, %AppSettings{id: Ecto.UUID.generate()}),
               request
             )

    assert {:error, :session_unavailable} =
             Launch.enqueue(
               %{base | session_id: Ecto.UUID.generate()}
               |> Map.put(:settings, context.trusted_settings),
               request
             )

    assert {:error, :session_unavailable} =
             Launch.enqueue(
               base
               |> Map.put(:settings, context.trusted_settings)
               |> Map.put(:session, %Session{id: context.session.id}),
               request
             )

    assert Runs.list_runs(session_id: context.session.id) == []
  end

  test "grounded selections are readiness-checked before launch normalization" do
    settings = %{
      "search" => %{"providers" => %{}},
      "grounded_providers" => %{
        "openai_responses" => %{"api_key" => "", "model" => "gpt-test"}
      }
    }

    request = %{
      level: "low",
      ranked_providers: [],
      grounded_providers: ["openai_responses"]
    }

    assert {:error,
            {:research_grounded_providers_unavailable,
             [%{provider: "openai_responses", ready?: false, reason: :missing_api_key}]}} =
             Launch.normalize_request(request, settings: settings)

    ready = put_in(settings, ["grounded_providers", "openai_responses", "api_key"], "key")
    assert {:ok, _launch} = Launch.normalize_request(request, settings: ready)
  end

  test "canonical enqueue preserves request idempotency and rejects semantic conflicts",
       context do
    request_key = Ecto.UUID.generate()

    launch_context = %{
      project_id: context.project.id,
      session_id: context.session.id,
      settings: context.trusted_settings,
      request_key: request_key,
      metadata: %{"source" => "canonical_launch"}
    }

    request = %{
      objective: "Compare durable provider coordination",
      level: "low",
      ranked_providers: ["duckduckgo"],
      max_sources: 8,
      attachments: []
    }

    assert {:ok, first} = Launch.enqueue(launch_context, request)
    assert {:ok, duplicate} = Launch.enqueue(launch_context, request)
    assert duplicate.id == first.id
    assert first.request_key == request_key
    assert first.metadata["source"] == "canonical_launch"

    assert first.metadata["research"]["provider_snapshot_ref"] =~
             "settings://research-routing/v2/"

    assert first.metadata["research"]["run_retry_policy"]["replay_safe"] == false
    assert Results.get_by_run(first)
    assert length(Runs.list_runs(session_id: context.session.id)) == 1

    conflicting = %{request | objective: "A different paid investigation"}
    assert {:error, :request_key_conflict} = Launch.enqueue(launch_context, conflicting)
    assert length(Runs.list_runs(session_id: context.session.id)) == 1
  end

  test "explicit budgets below known manifest reservations fail before insertion", context do
    request = %{
      objective: "Reject impossible budget",
      level: "low",
      ranked_providers: ["duckduckgo"],
      max_sources: 4
    }

    launch_context = %{
      project_id: context.project.id,
      session_id: context.session.id,
      settings: context.trusted_settings,
      request_key: Ecto.UUID.generate(),
      token_budget: 75_999,
      cost_budget_cents: 10_000
    }

    assert {:error,
            {:research_budget_below_manifest_requirement,
             %{dimension: :tokens, provided: 75_999, required: 76_000}}} =
             Launch.enqueue(launch_context, request)

    assert Runs.list_runs(session_id: context.session.id) == []

    assert {:error,
            {:research_budget_below_manifest_requirement,
             %{dimension: :cost_cents, provided: 2_499, required: 2_500}}} =
             Launch.enqueue(
               %{launch_context | token_budget: 76_000, cost_budget_cents: 2_499},
               request
             )

    assert Runs.list_runs(session_id: context.session.id) == []
  end

  test "routing snapshots are deterministic non-secret revision references", context do
    secret_settings = %{
      "settings_identity" => %{"id" => "settings-1", "lock_version" => 4},
      "auto_save" => true,
      "search" => %{
        "order" => ["brave", "exa"],
        "providers" => %{
          "brave" => %{
            "enabled" => true,
            "api_key" => "snapshot-secret-key",
            "base_url" => "https://brave.example",
            "engine" => "web"
          },
          "exa" => %{
            "enabled" => true,
            "api_key" => "exa-secret-key",
            "base_url" => "https://exa.example"
          }
        }
      },
      "synthesis_providers" => %{
        "openai" => %{"base_url" => "https://models.example", "api_key" => "model-secret"},
        "anthropic" => %{
          "base_url" => "https://anthropic-models.example",
          "api_key" => "anthropic-secret"
        }
      }
    }

    session = %{
      id: context.session.id,
      model_provider: "openai",
      model_name: "gpt-private-route"
    }

    reference = Launch.settings_snapshot_ref(secret_settings, session)

    assert reference =~ ~r/\Asettings:\/\/research-routing\/v2\/[0-9a-f]{64}\z/
    refute reference =~ "snapshot-secret-key"
    refute reference =~ "gpt-private-route"
    refute reference =~ "openai"
    assert :ok = Launch.validate_snapshot_ref(reference, secret_settings, session)

    unrelated_change =
      secret_settings
      |> put_in(["settings_identity", "lock_version"], 5)
      |> Map.put("auto_save", false)

    assert :ok = Launch.validate_snapshot_ref(reference, unrelated_change, session)

    credential_change =
      secret_settings
      |> put_in(["search", "providers", "brave", "api_key"], "rotated-secret")
      |> put_in(["synthesis_providers", "openai", "api_key"], "rotated-model-secret")

    assert :ok = Launch.validate_snapshot_ref(reference, credential_change, session)

    selected_reference =
      Launch.settings_snapshot_ref(secret_settings, session, ["brave"], [])

    unselected_route_change =
      put_in(
        secret_settings,
        ["search", "providers", "exa", "base_url"],
        "https://new-exa.example"
      )

    assert :ok =
             Launch.validate_snapshot_ref(
               selected_reference,
               unselected_route_change,
               session,
               ["brave"],
               []
             )

    provider_missing_from_order =
      put_in(secret_settings, ["search", "order"], ["exa"])

    missing_order_reference =
      Launch.settings_snapshot_ref(provider_missing_from_order, session, ["brave"], [])

    changed_missing_order_provider =
      put_in(
        provider_missing_from_order,
        ["search", "providers", "brave", "base_url"],
        "https://changed-brave.example"
      )

    assert {:error, :provider_configuration_changed} =
             Launch.validate_snapshot_ref(
               missing_order_reference,
               changed_missing_order_provider,
               session,
               ["brave"],
               []
             )

    mismatched_session = %{session | model_provider: "openai", model_name: "claude-test"}
    mismatched_reference = Launch.settings_snapshot_ref(secret_settings, mismatched_session)

    assert {:error, :provider_configuration_changed} =
             Launch.validate_snapshot_ref(
               mismatched_reference,
               put_in(
                 secret_settings,
                 ["synthesis_providers", "openai", "base_url"],
                 "https://changed-openai.example"
               ),
               mismatched_session
             )

    for changed_settings <- [
          put_in(
            secret_settings,
            ["search", "providers", "brave", "base_url"],
            "https://new-brave.example"
          ),
          put_in(secret_settings, ["search", "providers", "brave", "engine"], "news"),
          put_in(secret_settings, ["search", "providers", "brave", "enabled"], false),
          put_in(secret_settings, ["search", "order"], ["exa", "brave"]),
          put_in(
            secret_settings,
            ["synthesis_providers", "openai", "base_url"],
            "https://new-models.example"
          )
        ] do
      assert {:error, :provider_configuration_changed} =
               Launch.validate_snapshot_ref(reference, changed_settings, session)
    end

    assert {:error, :provider_configuration_changed} =
             Launch.validate_snapshot_ref(reference, secret_settings, %{
               session
               | model_name: "gpt-2"
             })

    assert {:error, :invalid_provider_snapshot_ref} =
             Launch.validate_snapshot_ref(
               "settings://research-routing/v2/not-a-digest",
               secret_settings,
               session
             )
  end

  test "canonical enqueue ignores an untrusted caller snapshot override", context do
    supplied = "settings://research-routing/v1/" <> String.duplicate("0", 64)

    assert {:ok, run} =
             Launch.enqueue(
               %{
                 project_id: context.project.id,
                 session_id: context.session.id,
                 session: context.session,
                 settings: context.trusted_settings,
                 request_key: Ecto.UUID.generate()
               },
               %{
                 objective: "Pin trusted provider routing",
                 level: "low",
                 ranked_providers: ["duckduckgo"],
                 provider_snapshot_ref: supplied
               }
             )

    expected =
      Launch.settings_snapshot_ref(
        context.trusted_settings,
        context.session,
        ["duckduckgo"],
        []
      )

    assert run.metadata["research"]["provider_snapshot_ref"] == expected
    refute run.metadata["research"]["provider_snapshot_ref"] == supplied
  end
end
