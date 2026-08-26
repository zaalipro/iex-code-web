defmodule IexCode.SettingsTest do
  use IexCode.DataCase, async: false
  @moduletag timeout: 120_000
  alias IexCode.Settings
  alias IexCode.Settings.AppSettings
  alias IexCode.Repo

  setup do
    IexCode.DataCase.drain_all_processes()
    Repo.delete_all(AppSettings)
    :ok
  end

  describe "get_settings/0 and update_settings/1" do
    test "schema, persisted, and execution-policy defaults use one canonical model profile" do
      schema_defaults = %AppSettings{}
      persisted = Settings.get_settings()
      policy = Settings.execution_policy(schema_defaults)

      assert schema_defaults.default_model_provider == "openai"
      assert schema_defaults.default_model == "deepseek-v4-pro"
      assert schema_defaults.openai_base_url == "https://cli.llmotions.com/v1"
      assert persisted.default_model_provider == schema_defaults.default_model_provider
      assert persisted.default_model == schema_defaults.default_model
      assert persisted.openai_base_url == schema_defaults.openai_base_url
      assert policy["model_provider"] == schema_defaults.default_model_provider
      assert policy["model_name"] == schema_defaults.default_model
    end

    test "initializes default settings when database is empty" do
      settings = Settings.get_settings()
      assert %AppSettings{} = settings
      assert settings.default_model == "deepseek-v4-pro"
      assert settings.openai_base_url == "https://cli.llmotions.com/v1"
      # No default API key is ever injected; it must come from the environment or stay unset.
      assert settings.openai_api_key in [nil, "", System.get_env("OPENAI_API_KEY")]
    end

    test "redacts model and search credentials from inspected settings" do
      settings = %AppSettings{
        openai_api_key: "openai-inspect-secret",
        anthropic_api_key: "anthropic-inspect-secret",
        search_providers: %{
          "perplexity" => %{"enabled" => true, "api_key" => "search-inspect-secret"}
        }
      }

      inspected = inspect(settings)

      refute inspected =~ "openai-inspect-secret"
      refute inspected =~ "anthropic-inspect-secret"
      refute inspected =~ "search-inspect-secret"
    end

    test "does not emit credentials in SQL logs during settings insert or update" do
      sentinel = "sentinel-search-key-that-must-never-be-logged"

      captured =
        ExUnit.CaptureLog.capture_log([level: :debug], fn ->
          assert {:ok, updated} =
                   Settings.update_settings(%{
                     search_providers: %{
                       "perplexity" => %{
                         "enabled" => true,
                         "api_key" => sentinel,
                         "base_url" => "https://api.perplexity.ai"
                       }
                     },
                     search_provider_order: ["perplexity"]
                   })

          assert updated.search_providers["perplexity"]["api_key"] == sentinel

          assert {:ok, updated_again} =
                   Settings.update_settings(%{
                     search_providers: %{
                       "perplexity" => %{
                         "enabled" => false,
                         "api_key" => sentinel,
                         "base_url" => "https://api.perplexity.ai"
                       }
                     },
                     search_provider_order: ["perplexity"]
                   })

          assert updated_again.search_providers["perplexity"]["api_key"] == sentinel
          refute updated_again.search_providers["perplexity"]["enabled"]
        end)

      refute captured =~ sentinel
    end

    test "safely handles multiple AppSettings rows without raising MultipleResultsError" do
      Repo.delete_all(AppSettings)
      # The singleton index (app_settings_singleton_index) now forbids a second row.
      {:ok, s1} = Repo.insert(%AppSettings{default_model: "model-1", openai_api_key: "k1"})

      assert_raise Ecto.ConstraintError, fn ->
        Repo.insert(%AppSettings{default_model: "model-2", openai_api_key: "k2"})
      end

      # get_settings() safely returns the single existing row
      settings = Settings.get_settings()
      assert %AppSettings{} = settings
      assert settings.id == s1.id
    end

    test "updates existing settings idempotently" do
      {:ok, updated} =
        Settings.update_settings(%{
          default_model: "claude-3-5-sonnet",
          default_model_provider: "anthropic",
          anthropic_api_key: "sk-ant-test12345",
          anthropic_base_url: "https://api.anthropic.com",
          openai_api_key: "sk-proj-test12345",
          openai_base_url: "https://api.openai.com/v1",
          swarm_agent_count: 6,
          temperature: 0.7,
          max_tokens: 8192,
          auto_save: true
        })

      assert updated.default_model == "claude-3-5-sonnet"
      assert updated.default_model_provider == "anthropic"
      assert updated.anthropic_api_key == "sk-ant-test12345"
      assert updated.anthropic_base_url == "https://api.anthropic.com"
      assert updated.openai_api_key == "sk-proj-test12345"
      assert updated.openai_base_url == "https://api.openai.com/v1"
      assert updated.swarm_agent_count == 6
      assert updated.temperature == 0.7
      assert updated.max_tokens == 8192
      assert updated.auto_save == true

      fetched = Settings.get_settings()
      assert fetched.default_model == "claude-3-5-sonnet"
      assert fetched.temperature == 0.7
      assert fetched.max_tokens == 8192
    end

    test "form updates reject a stale settings revision instead of overwriting newer values" do
      stale = Settings.get_settings()

      assert {:ok, latest} =
               Settings.update_settings(%{default_run_priority: "high"})

      assert latest.lock_version > stale.lock_version

      assert {:error, :stale_settings} =
               Settings.update_settings_from_form(stale, %{
                 "default_run_priority" => "low"
               })

      assert Settings.get_settings().default_run_priority == "high"
    end

    test "execution policy settings reject every out-of-contract value" do
      settings = Settings.get_settings()

      invalid =
        Settings.change_settings(settings, %{
          default_dispatch_mode: "automatic",
          default_run_mode: "code",
          default_run_priority: "urgent",
          default_run_max_attempts: 0,
          default_run_token_budget: 0,
          default_run_cost_budget_cents: 10_000_001,
          default_run_time_budget_minutes: 10_081,
          goal_auto_start: nil,
          agent_max_turns: 21,
          swarm_max_retries: 11,
          default_tools: %{"unknown" => true}
        })

      refute invalid.valid?
      errors = errors_on(invalid)

      for field <- [
            :default_dispatch_mode,
            :default_run_mode,
            :default_run_priority,
            :default_run_max_attempts,
            :default_run_token_budget,
            :default_run_cost_budget_cents,
            :default_run_time_budget_minutes,
            :goal_auto_start,
            :agent_max_turns,
            :swarm_max_retries,
            :default_tools
          ] do
        assert Map.has_key?(errors, field), "expected an error for #{field}"
      end
    end

    test "persists validated federated search and research defaults" do
      providers =
        Settings.get_settings().search_providers
        |> disable_all_search_providers()
        |> Map.put("tavily", %{
          "enabled" => true,
          "api_key" => "tvly-test",
          "base_url" => "https://api.tavily.com"
        })
        |> Map.put("duckduckgo", %{"enabled" => true})

      assert {:ok, updated} =
               Settings.update_settings(%{
                 search_providers: providers,
                 search_provider_order: ["tavily", "duckduckgo"],
                 research_depth: "deep",
                 research_level: "ultra",
                 research_max_sources: 24,
                 research_parallelism: 6,
                 research_require_conflict_audit: false,
                 research_max_cost_cents: 12_345,
                 research_max_tokens: 543_210,
                 research_time_budget_minutes: 75
               })

      assert updated.search_providers["tavily"] == providers["tavily"]
      assert updated.search_providers["duckduckgo"]["enabled"] == true

      assert updated.search_providers["duckduckgo"]["base_url"] ==
               "https://html.duckduckgo.com"

      assert Map.has_key?(updated.search_providers, "brave")
      assert Enum.take(updated.search_provider_order, 2) == ["tavily", "duckduckgo"]

      assert Enum.sort(updated.search_provider_order) ==
               Enum.sort(Map.keys(updated.search_providers))

      assert Enum.uniq(updated.search_provider_order) == updated.search_provider_order

      assert Settings.search_config(updated) == %{
               providers: updated.search_providers,
               order: ["tavily", "duckduckgo"],
               depth: "deep",
               level: "ultra",
               max_sources: 24,
               parallelism: 6,
               require_conflict_audit: false,
               max_cost_cents: 12_345,
               max_tokens: 543_210,
               time_budget_minutes: 75
             }

      invalid = Settings.change_settings(updated, %{search_provider_order: ["unknown"]})
      refute invalid.valid?
      assert %{search_provider_order: _} = errors_on(invalid)
    end

    test "provider hydration preserves an explicit disabled value" do
      providers =
        Settings.get_settings().search_providers
        |> disable_all_search_providers()
        |> Map.put("duckduckgo", %{"enabled" => false})

      assert {:ok, updated} =
               Settings.update_settings(%{
                 search_providers: providers,
                 search_provider_order: ["duckduckgo"]
               })

      assert updated.search_providers["duckduckgo"]["enabled"] == false

      assert updated.search_providers["duckduckgo"]["base_url"] ==
               "https://html.duckduckgo.com"

      assert Settings.search_config(updated).order == []
    end

    test "automatic search selection excludes retired provider adapters" do
      providers =
        Settings.get_settings().search_providers
        |> disable_all_search_providers()
        |> put_in(["bing", "enabled"], true)
        |> put_in(["duckduckgo", "enabled"], true)

      assert {:ok, updated} =
               Settings.update_settings(%{
                 search_providers: providers,
                 search_provider_order: ["bing", "duckduckgo"]
               })

      assert Settings.search_config(updated).order == ["duckduckgo"]
    end

    test "hydrates modern ranked provider defaults and validates SerpApi engines" do
      settings = Settings.get_settings()

      for {provider, host} <- [
            {"perplexity", "api.perplexity.ai"},
            {"firecrawl", "api.firecrawl.dev"},
            {"linkup", "api.linkup.so"},
            {"serpapi", "serpapi.com"}
          ] do
        assert provider in settings.search_provider_order
        assert URI.parse(settings.search_providers[provider]["base_url"]).host == host
      end

      assert settings.search_providers["serpapi"]["engine"] == "google"

      invalid =
        Settings.change_settings(settings, %{
          search_providers: put_in(settings.search_providers, ["serpapi", "engine"], "arbitrary")
        })

      refute invalid.valid?
      assert %{search_providers: _} = errors_on(invalid)
    end

    test "upgrades a customized legacy provider order against the hydrated provider set" do
      legacy_providers = %{
        "tavily" => %{"enabled" => false},
        "brave" => %{"enabled" => false},
        "exa" => %{"enabled" => false},
        "serper" => %{"enabled" => false},
        "google" => %{"enabled" => false},
        "bing" => %{"enabled" => false},
        "searxng" => %{"enabled" => false},
        "duckduckgo" => %{"enabled" => true}
      }

      customized_legacy_order = [
        "duckduckgo",
        "tavily",
        "unknown-provider",
        "duckduckgo",
        "bing",
        "searxng",
        "google",
        "serper",
        "exa",
        "brave",
        ""
      ]

      {:ok, _stored} =
        Repo.insert(%AppSettings{
          search_providers: legacy_providers,
          search_provider_order: customized_legacy_order
        })

      upgraded = Settings.get_settings()

      expected_order = [
        "duckduckgo",
        "tavily",
        "bing",
        "searxng",
        "google",
        "serper",
        "exa",
        "brave",
        "perplexity",
        "firecrawl",
        "linkup",
        "serpapi"
      ]

      assert upgraded.search_provider_order == expected_order
      assert Enum.uniq(upgraded.search_provider_order) == upgraded.search_provider_order

      assert Map.keys(upgraded.search_providers) |> Enum.sort() ==
               Enum.sort(expected_order)

      for provider <- ~w(perplexity firecrawl linkup serpapi) do
        assert Enum.count(upgraded.search_provider_order, &(&1 == provider)) == 1
        assert Map.has_key?(upgraded.search_providers, provider)
      end
    end

    test "fixed ranked providers cannot redirect credentials to attacker endpoints" do
      settings = Settings.get_settings()

      for provider <- ["tavily", "perplexity", "firecrawl", "linkup", "serpapi"] do
        config =
          settings.search_providers
          |> Map.fetch!(provider)
          |> Map.put("enabled", true)
          |> Map.put("api_key", "must-not-exfiltrate")
          |> Map.put("base_url", "https://attacker.example/collect")

        changeset =
          Settings.change_settings(settings, %{
            search_providers: Map.put(settings.search_providers, provider, config)
          })

        refute changeset.valid?, "expected #{provider} attacker URL to be rejected"
        assert %{search_providers: _} = errors_on(changeset)
      end

      tavily_http =
        settings.search_providers
        |> Map.fetch!("tavily")
        |> Map.put("base_url", "http://api.tavily.com")

      refute Settings.change_settings(settings, %{
               search_providers: Map.put(settings.search_providers, "tavily", tavily_http)
             }).valid?

      searxng =
        settings.search_providers
        |> Map.fetch!("searxng")
        |> Map.put("enabled", true)
        |> Map.put("base_url", "http://localhost:8080")

      assert Settings.change_settings(settings, %{
               search_providers: Map.put(settings.search_providers, "searxng", searxng)
             }).valid?
    end

    test "provider configs reject duplicate atom/string aliases before JSON persistence" do
      settings = Settings.get_settings()

      ambiguous = %{
        "enabled" => true,
        "api_key" => "secret",
        "base_url" => "https://api.tavily.com",
        base_url: "https://attacker.example/collect"
      }

      changeset =
        Settings.change_settings(settings, %{
          search_providers: Map.put(settings.search_providers, "tavily", ambiguous)
        })

      refute changeset.valid?
      assert %{search_providers: _} = errors_on(changeset)

      encoded = Jason.encode!(ambiguous)
      assert encoded =~ ~s("base_url":"https://api.tavily.com")
      assert encoded =~ ~s("base_url":"https://attacker.example/collect")
    end

    test "validates temperature and max_tokens ranges in changeset" do
      settings = Settings.get_settings()

      # Valid bounds
      valid_cs =
        Settings.change_settings(settings, %{
          temperature: 0.0,
          max_tokens: 128_000,
          swarm_agent_count: 32
        })

      assert valid_cs.valid?

      # Invalid temperature
      invalid_temp = Settings.change_settings(settings, %{temperature: 2.5})
      refute invalid_temp.valid?
      assert %{temperature: _} = errors_on(invalid_temp)

      # Invalid max_tokens
      invalid_tokens = Settings.change_settings(settings, %{max_tokens: 0})
      refute invalid_tokens.valid?
      assert %{max_tokens: _} = errors_on(invalid_tokens)
    end

    test "persists validated execution policy defaults and returns a secret-free snapshot" do
      assert {:ok, updated} =
               Settings.update_settings(%{
                 default_dispatch_mode: "interactive",
                 default_run_mode: "dag",
                 default_run_priority: "high",
                 default_run_max_attempts: 6,
                 default_run_token_budget: 250_000,
                 default_run_cost_budget_cents: 8_000,
                 default_run_time_budget_minutes: 180,
                 goal_auto_start: false,
                 agent_max_turns: 12,
                 swarm_agent_count: 8,
                 swarm_max_retries: 5,
                 default_tools: %{"ast_search" => true, "web_search" => true},
                 openai_api_key: "policy-secret",
                 openai_base_url: "https://models.example.test/v1"
               })

      policy =
        Settings.execution_policy(updated, %{
          model_provider: "anthropic",
          model_name: "claude-test",
          temperature: 0.6
        })

      assert policy["version"] == 1
      assert policy["dispatch_mode"] == "interactive"
      assert policy["run_mode"] == "dag"
      assert policy["run_priority"] == "high"
      assert policy["run_max_attempts"] == 6
      assert policy["run_token_budget"] == 250_000
      assert policy["run_cost_budget_cents"] == 8_000
      assert policy["run_time_budget_minutes"] == 180
      assert policy["goal_auto_start"] == false
      assert policy["agent_max_turns"] == 12
      assert policy["swarm_agent_count"] == 8
      assert policy["swarm_max_retries"] == 5
      assert policy["model_provider"] == "anthropic"
      assert policy["model_name"] == "claude-test"
      assert policy["temperature"] == 0.6
      assert "ast_search" in policy["allowed_tools"]
      assert "web_search" in policy["allowed_tools"]

      serialized = inspect(policy)
      refute serialized =~ "policy-secret"
      refute serialized =~ "models.example.test"

      assert {:error, _reason} =
               Settings.execution_policy(updated, nil, %{"swarm_agent_count" => 3})
    end

    test "normalizes forms strictly, preserves blank secrets, reorders providers, and clears credentials" do
      assert {:ok, current} =
               Settings.update_settings(%{
                 openai_api_key: "openai-existing",
                 anthropic_api_key: "anthropic-existing",
                 search_providers: %{
                   "tavily" => %{
                     "enabled" => true,
                     "api_key" => "tavily-existing",
                     "base_url" => "https://api.tavily.com"
                   },
                   "duckduckgo" => %{
                     "enabled" => true,
                     "base_url" => "https://html.duckduckgo.com"
                   }
                 },
                 search_provider_order: ["tavily", "duckduckgo"]
               })

      assert {:ok, updated} =
               Settings.update_settings_from_form(current, %{
                 "openai_api_key" => "  ",
                 "anthropic_api_key" => "",
                 "default_run_max_attempts" => "7",
                 "search_provider_order" => "duckduckgo,tavily",
                 "search_providers" => %{
                   "tavily" => %{"enabled" => "true", "api_key" => ""}
                 }
               })

      assert updated.openai_api_key == "openai-existing"
      assert updated.anthropic_api_key == "anthropic-existing"
      assert updated.search_providers["tavily"]["api_key"] == "tavily-existing"
      assert Enum.take(updated.search_provider_order, 2) == ["duckduckgo", "tavily"]
      assert updated.default_run_max_attempts == 7

      assert {:error, changeset} =
               Settings.update_settings_from_form(updated, %{
                 "default_run_max_attempts" => "5suffix"
               })

      assert %{default_run_max_attempts: _} = errors_on(changeset)

      assert {:ok, cleared} = Settings.clear_credential(updated, :openai)
      assert cleared.openai_api_key in [nil, ""]

      assert {:ok, cleared} = Settings.clear_credential(cleared, {:search, "tavily"})
      assert cleared.search_providers["tavily"]["api_key"] == ""
    end

    test "blank form values preserve only secrets and clear or reset non-secret provider fields" do
      assert {:ok, current} =
               Settings.update_settings(%{
                 search_providers: %{
                   "searxng" => %{
                     "enabled" => true,
                     "base_url" => "http://localhost:8080"
                   },
                   "google" => %{
                     "enabled" => false,
                     "api_key" => "google-secret",
                     "base_url" => "https://customsearch.googleapis.com",
                     "engine_id" => "engine-to-clear"
                   },
                   "serpapi" => %{
                     "enabled" => true,
                     "api_key" => "serpapi-secret",
                     "base_url" => "https://serpapi.com",
                     "engine" => "bing"
                   }
                 },
                 search_provider_order: ["searxng", "google", "serpapi"]
               })

      assert {:ok, updated} =
               Settings.update_settings_from_form(current, %{
                 "search_providers" => %{
                   "searxng" => %{"enabled" => "false", "base_url" => "  "},
                   "google" => %{
                     "enabled" => "false",
                     "api_key" => "",
                     "engine_id" => " "
                   },
                   "serpapi" => %{
                     "enabled" => "true",
                     "api_key" => "  ",
                     "engine" => ""
                   }
                 }
               })

      assert updated.search_providers["searxng"]["base_url"] == ""
      assert updated.search_providers["google"]["engine_id"] == ""
      assert updated.search_providers["google"]["api_key"] == "google-secret"
      assert updated.search_providers["serpapi"]["api_key"] == "serpapi-secret"
      assert updated.search_providers["serpapi"]["engine"] == "google"
    end

    test "broadcasts successful updates and never raises for non-JSON provider input" do
      assert :ok = Settings.subscribe()
      assert {:ok, updated} = Settings.update_settings(%{swarm_agent_count: 9})
      assert_receive {:settings_updated, ^updated}

      changeset =
        Settings.change_settings(updated, %{
          search_providers: %{"tavily" => %{"enabled" => true, "unexpected" => self()}}
        })

      refute changeset.valid?
      assert %{search_providers: _} = errors_on(changeset)
    end

    test "requires bounded scalar values and http(s) model endpoints" do
      settings = Settings.get_settings()

      invalid =
        Settings.change_settings(settings, %{
          default_model: String.duplicate("x", 241),
          openai_api_key: String.duplicate("k", 4_097),
          openai_base_url: "file:///tmp/model",
          anthropic_base_url: "https://user:password@example.com",
          swarm_agent_count: 3,
          research_max_sources: 41
        })

      refute invalid.valid?
      errors = errors_on(invalid)
      assert %{default_model: _, openai_api_key: _, openai_base_url: _} = errors
      assert %{anthropic_base_url: _, swarm_agent_count: _, research_max_sources: _} = errors
    end

    test "normalizes default tools without dynamic atom conversion" do
      settings = Settings.get_settings()

      assert %{
               "ast_search" => true,
               "web_search" => false
             } =
               Settings.normalize_form_params(
                 %{
                   "default_tools" => %{
                     "ast_search" => "true",
                     "web_search" => "false"
                   }
                 },
                 settings
               )["default_tools"]

      assert {:ok, updated} =
               Settings.update_settings(%{default_tools: %{ast_search: false, web_search: true}})

      policy = Settings.execution_policy(updated)
      refute "ast_search" in policy["allowed_tools"]
      assert "web_search" in policy["allowed_tools"]
    end

    test "change_settings/2 returns a valid changeset" do
      settings = Settings.get_settings()
      changeset = Settings.change_settings(settings, %{default_model: "o3-mini"})
      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :default_model) == "o3-mini"
    end
  end

  defp disable_all_search_providers(providers) do
    Map.new(providers, fn {provider, config} ->
      {provider, Map.put(config, "enabled", false)}
    end)
  end
end
