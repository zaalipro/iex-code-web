defmodule IexCodeWeb.SettingsLiveTest do
  use IexCode.E2E.Case, async: false

  alias IexCode.{Repo, Sessions, Settings}
  alias IexCode.Settings.AppSettings

  test "global route renders every settings section and accessible save controls", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    assert has_element?(view, "#settings-page")
    assert has_element?(view, "#settings-form[phx-submit='save_settings']")
    assert has_element?(view, "#settings-return-workspace[href='/']")
    assert has_element?(view, "#settings-logout-form[action='/logout'][method='post']")

    for section <- ~w(models execution goals swarm research providers editor usage runtime) do
      assert has_element?(view, "section##{section}")
      assert has_element?(view, "#settings-nav-#{section}[href='##{section}']")
    end

    assert has_element?(view, "#settings-save-bar #settings-save[type='submit'][disabled]")
    assert has_element?(view, "#settings-save-bar #settings-discard[type='button'][disabled]")

    assert has_element?(
             view,
             "label[for='settings-default-model-provider']",
             "Default API protocol"
           )

    assert has_element?(
             view,
             "#models",
             "The selected provider is authoritative; model identifiers are passed through unchanged"
           )

    assert has_element?(view, "#settings-default-model[maxlength='240']")
    assert has_element?(view, "label[for='settings-swarm-agent-count']")

    assert has_element?(
             view,
             "label[for='settings-default-run-max-attempts']",
             "Manual retry ceiling"
           )

    assert has_element?(
             view,
             "#settings-run-attempt-policy",
             "first run plus up to two user-requested retries"
           )

    assert has_element?(
             view,
             "label[for='settings-swarm-max-retries']",
             "Swarm self-healing retries"
           )

    assert has_element?(
             view,
             "#settings-default-run-max-attempts[aria-description*='Counts the initial execution']"
           )

    assert has_element?(view, "#settings-save[aria-describedby='settings-save-status']")
    assert has_element?(view, "#settings-discard[aria-describedby='settings-save-status']")
    assert has_element?(view, "#settings-default-tools", "Optional tools for new runs")
    assert has_element?(view, "#settings-core-tools-note", "Core workspace read, edit, terminal")

    assert has_element?(
             view,
             "#settings-research-zero-cap-note",
             "Entering 0 blocks any research manifest"
           )

    assert has_element?(
             view,
             "#settings-research-max-tokens[min='0'][aria-description*='Hard admission cap']"
           )

    assert has_element?(
             view,
             "#settings-research-max-cost[min='0'][aria-description*='Hard admission cap']"
           )

    assert has_element?(
             view,
             "#settings-page",
             "Existing sessions retain only their session-level provider"
           )
  end

  test "session route shows valid context, scopes the return link, and rejects invalid context safely",
       %{
         conn: conn,
         workspace_path: path
       } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project, %{title: "Settings scope session"})

    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}/settings")

    assert has_element?(view, "#settings-session-context", "Settings scope session")
    assert has_element?(view, "#settings-return-workspace[href='/sessions/#{session.id}']")

    assert has_element?(view, "#settings-usage-empty") or
             has_element?(view, "#settings-usage-ready")

    {:ok, invalid_view, _html} = live(conn, "/sessions/not-a-valid-session/settings")
    refute has_element?(invalid_view, "#settings-session-context")
    assert has_element?(invalid_view, "#settings-session-context-error[role='status']")
    assert has_element?(invalid_view, "#settings-return-workspace[href='/']")
  end

  test "provider filter handles form change events from paste and native search input", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/settings")

    assert has_element?(view, "#settings-provider-filter[name='provider_filter']")

    view
    |> element("#settings-provider-filter")
    |> render_change(%{"provider_filter" => "duck"})

    assert has_element?(view, "#settings-search-provider-duckduckgo")
    refute has_element?(view, "#settings-search-provider-tavily")

    view
    |> element("#settings-provider-filter")
    |> render_change(%{"provider_filter" => "no-such-provider"})

    assert has_element?(view, "#settings-provider-filter-empty")
  end

  test "valid save persists global execution defaults and stays on the settings page", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/settings")

    view
    |> form("#settings-form", %{"settings" => %{"default_run_priority" => "high"}})
    |> render_change()

    assert has_element?(view, "#settings-save-status", "Unsaved changes")
    assert has_element?(view, "#settings-save:not([disabled])")
    assert has_element?(view, "#settings-discard:not([disabled])")

    view |> element("#settings-discard") |> render_click()
    assert has_element?(view, "#settings-save-status", "Changes discarded")
    assert has_element?(view, "#settings-save[disabled]")
    assert has_element?(view, "#settings-discard[disabled]")

    save_form =
      form(view, "#settings-form", %{
        "settings" => %{
          "default_dispatch_mode" => "interactive",
          "default_run_mode" => "single",
          "default_run_priority" => "high",
          "default_run_max_attempts" => "5",
          "agent_max_turns" => "12",
          "swarm_agent_count" => "6"
        }
      })

    render_change(save_form)
    assert has_element?(view, "#settings-save:not([disabled])")
    render_submit(save_form)

    assert has_element?(view, "#settings-page")
    assert has_element?(view, "#settings-save-status", "Saved")
    assert has_element?(view, "#settings-save[disabled]")
    assert has_element?(view, "#settings-discard[disabled]")

    assert has_element?(
             view,
             "#settings-default-dispatch-mode option[value='interactive'][selected]"
           )

    saved = Settings.get_settings()
    assert saved.default_dispatch_mode == "interactive"
    assert saved.default_run_mode == "single"
    assert saved.default_run_priority == "high"
    assert saved.default_run_max_attempts == 5
    assert saved.agent_max_turns == 12
    assert saved.swarm_agent_count == 6
  end

  test "dirty and invalid drafts arm the navigation guard until save or discard", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    assert has_element?(view, "#settings-client-behaviors[data-dirty='false']")
    refute has_element?(view, "#settings-return-workspace[data-unsaved-confirm]")

    view
    |> form("#settings-form", %{"settings" => %{"default_model" => "pending-navigation"}})
    |> render_change()

    assert has_element?(view, "#settings-client-behaviors[data-dirty='true']")

    assert has_element?(
             view,
             "#settings-return-workspace[data-settings-navigation][data-unsaved-confirm]"
           )

    view |> element("#settings-discard") |> render_click()
    assert has_element?(view, "#settings-client-behaviors[data-dirty='false']")
    refute has_element?(view, "#settings-return-workspace[data-unsaved-confirm]")

    view
    |> form("#settings-form", %{"settings" => %{"max_tokens" => "0"}})
    |> render_submit()

    assert has_element?(view, "#settings-client-behaviors[data-dirty='true']")
    assert has_element?(view, "#settings-return-workspace[data-unsaved-confirm]")
  end

  test "invalid save retains attempted values and renders field and summary errors", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    view
    |> form("#settings-form", %{
      "settings" => %{
        "max_tokens" => "0",
        "swarm_agent_count" => "3",
        "research_max_sources" => "41"
      }
    })
    |> render_submit()

    assert has_element?(view, "#settings-error-summary[role='alert']")
    assert has_element?(view, "#settings-max-tokens[value='0'][aria-invalid='true']")
    assert has_element?(view, "#settings-swarm-agent-count[value='3'][aria-invalid='true']")
    assert has_element?(view, "#settings-research-max-sources[value='41'][aria-invalid='true']")
    assert has_element?(view, "#settings-save-status", "Needs attention")
  end

  test "secrets are never rendered and explicit clear removes only the selected credential", %{
    conn: conn
  } do
    openai_secret = "openai-ui-secret-#{System.unique_integer([:positive])}"
    anthropic_secret = "anthropic-ui-secret-#{System.unique_integer([:positive])}"

    assert {:ok, _settings} =
             Settings.update_settings(%{
               openai_api_key: openai_secret,
               anthropic_api_key: anthropic_secret
             })

    {:ok, view, html} = live(conn, ~p"/settings")

    refute html =~ openai_secret
    refute html =~ anthropic_secret
    assert has_element?(view, "#settings-openai-api-key[value='']")
    assert has_element?(view, "#settings-clear-openai[data-confirm]")
    assert has_element?(view, "#settings-clear-openai[data-confirm*='immediately']")

    view |> element("#settings-clear-openai") |> render_click()

    saved = Settings.get_settings()
    assert saved.openai_api_key in [nil, ""]
    assert saved.anthropic_api_key == anthropic_secret
    refute render(view) =~ anthropic_secret
    refute has_element?(view, "#settings-clear-openai")
    assert has_element?(view, "#settings-save-status", "Credential removed")
    assert has_element?(view, "#settings-save[disabled]")

    view
    |> form("#settings-form", %{"settings" => %{"default_model" => "pending-local-model"}})
    |> render_change()

    view |> element("#settings-clear-anthropic") |> render_click()

    persisted = Settings.get_settings()
    assert persisted.anthropic_api_key in [nil, ""]
    assert persisted.default_model == saved.default_model
    assert has_element?(view, "#settings-default-model[value='pending-local-model']")
    assert has_element?(view, "#settings-save-status", "Your other edits remain unsaved")
    assert has_element?(view, "#settings-save:not([disabled])")

    view |> element("#settings-discard") |> render_click()
    assert has_element?(view, "#settings-default-model[value='#{saved.default_model}']")
    assert has_element?(view, "#settings-save[disabled]")
  end

  test "credential removal preserves an invalid draft instead of resetting attempted values", %{
    conn: conn
  } do
    assert {:ok, _settings} = Settings.update_settings(%{openai_api_key: "clear-invalid-draft"})
    {:ok, view, _html} = live(conn, ~p"/settings")

    view
    |> form("#settings-form", %{
      "settings" => %{"max_tokens" => "0", "default_model" => "invalid-draft-model"}
    })
    |> render_submit()

    view |> element("#settings-clear-openai") |> render_click()

    assert Settings.get_settings().openai_api_key in [nil, ""]
    assert has_element?(view, "#settings-error-summary[role='alert']")
    assert has_element?(view, "#settings-max-tokens[value='0'][aria-invalid='true']")
    assert has_element?(view, "#settings-default-model[value='invalid-draft-model']")
    assert has_element?(view, "#settings-save-status", "invalid draft is preserved")
  end

  test "provider rows disclose honest status, filter, expand, and stage ordering", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    assert has_element?(
             view,
             "#settings-search-provider-tavily[data-provider-lifecycle='active']"
           )

    assert has_element?(view, "#settings-provider-status-tavily[data-tone='enabled']") or
             has_element?(view, "#settings-provider-status-tavily[data-tone='configured']") or
             has_element?(view, "#settings-provider-status-tavily[data-tone='missing']")

    refute has_element?(view, "#settings-provider-status-tavily", "Ready")

    assert has_element?(view, "#settings-search-provider-bing[data-provider-lifecycle='retired']")
    assert has_element?(view, "#settings-provider-enabled-bing[disabled]")

    view |> element("#settings-provider-advanced-tavily") |> render_click()
    assert has_element?(view, "#settings-provider-panel-tavily")
    assert has_element?(view, "#settings-provider-advanced-tavily[aria-label='Configure Tavily']")
    assert has_element?(view, "[role='group'][aria-label='Move Tavily in provider order']")
    assert has_element?(view, "label[for='settings-provider-key-tavily']")
    assert has_element?(view, "#settings-provider-url-tavily[readonly]")

    view
    |> element("#settings-provider-filter")
    |> render_change(%{"value" => "duck"})

    assert has_element?(view, "#settings-search-provider-duckduckgo")
    refute has_element?(view, "#settings-search-provider-tavily")

    view
    |> element("#settings-provider-filter")
    |> render_change(%{"value" => ""})

    original = Settings.get_settings().search_provider_order
    first = hd(original)
    second = Enum.at(original, 1)

    view |> element("#settings-provider-move-down-#{first}") |> render_click()

    assert Settings.get_settings().search_provider_order == original

    assert has_element?(
             view,
             "#settings-provider-order[value='#{Enum.join([second, first | Enum.drop(original, 2)], ",")}']"
           )

    assert has_element?(view, "#settings-save-status", "Save to apply it")
    assert has_element?(view, "#settings-save:not([disabled])")

    view |> element("#settings-discard") |> render_click()
    assert Settings.get_settings().search_provider_order == original
    assert has_element?(view, "#settings-provider-order[value='#{Enum.join(original, ",")}']")

    view |> element("#settings-provider-move-down-#{first}") |> render_click()
    reordered = [second, first | Enum.drop(original, 2)]

    view
    |> form("#settings-form", %{
      "settings" => %{"search_provider_order" => Enum.join(reordered, ",")}
    })
    |> render_submit()

    assert Settings.get_settings().search_provider_order == reordered
    assert has_element?(view, "#settings-save-status", "Settings saved")
  end

  test "customized legacy provider order hydrates every new provider into the UI once", %{
    conn: conn
  } do
    _settings = Settings.get_settings()

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

    customized_legacy_order =
      ~w(duckduckgo tavily bing searxng google serper exa brave)

    {1, nil} =
      Repo.update_all(AppSettings,
        set: [
          search_providers: legacy_providers,
          search_provider_order: customized_legacy_order
        ]
      )

    {:ok, view, _html} = live(conn, ~p"/settings")

    expected_order =
      customized_legacy_order ++ ~w(perplexity firecrawl linkup serpapi)

    assert has_element?(
             view,
             "#settings-provider-order[value='#{Enum.join(expected_order, ",")}']"
           )

    for provider <- ~w(perplexity firecrawl linkup serpapi) do
      assert has_element?(view, "#settings-search-provider-#{provider}")
    end
  end

  test "provider reordering preserves invalid draft values and remains discardable", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")
    original = Settings.get_settings().search_provider_order
    first = hd(original)

    view
    |> form("#settings-form", %{
      "settings" => %{"max_tokens" => "0", "default_model" => "provider-order-draft"}
    })
    |> render_submit()

    view |> element("#settings-provider-move-down-#{first}") |> render_click()

    assert Settings.get_settings().search_provider_order == original
    assert has_element?(view, "#settings-max-tokens[value='0'][aria-invalid='true']")
    assert has_element?(view, "#settings-default-model[value='provider-order-draft']")
    assert has_element?(view, "#settings-error-summary[role='alert']")

    view |> element("#settings-discard") |> render_click()
    assert has_element?(view, "#settings-provider-order[value='#{Enum.join(original, ",")}']")
    refute has_element?(view, "#settings-default-model[value='provider-order-draft']")
  end

  test "usage storage failures render an error rather than an honest empty state", %{conn: conn} do
    previous = Application.get_env(:iex_code, :usage_reader)
    Application.put_env(:iex_code, :usage_reader, IexCode.UsageFailureStub)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:iex_code, :usage_reader, previous),
        else: Application.delete_env(:iex_code, :usage_reader)
    end)

    {:ok, view, _html} = live(conn, ~p"/settings")
    assert has_element?(view, "#settings-usage-error[role='alert']")
    refute has_element?(view, "#settings-usage-empty")
  end

  test "usage is session scoped and never synthesizes zero-token rows", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project, %{title: "Usage settings scope"})
    other_session = create_session_fixture(project, %{title: "Other usage scope"})

    {:ok, own_message} =
      Sessions.create_message(%{
        session_id: session.id,
        role: "assistant",
        content: "Scoped usage",
        input_tokens: 21,
        output_tokens: 34,
        cost_cents: 7
      })

    {:ok, other_message} =
      Sessions.create_message(%{
        session_id: other_session.id,
        role: "assistant",
        content: "Other usage",
        input_tokens: 100,
        output_tokens: 200,
        cost_cents: 30
      })

    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}/settings")

    assert has_element?(view, "#settings-usage-row-#{own_message.id}")
    refute has_element?(view, "#settings-usage-row-#{other_message.id}")
    assert has_element?(view, "#settings-usage-ready", "55 tokens")
  end

  test "external updates never replace an invalid form with unsaved values", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    view
    |> form("#settings-form", %{"settings" => %{"max_tokens" => "0"}})
    |> render_submit()

    assert has_element?(view, "#settings-max-tokens[value='0'][aria-invalid='true']")
    external = %{Settings.get_settings() | default_model: "external-model-update"}
    send(view.pid, {:settings_updated, external})
    _ = :sys.get_state(view.pid)

    assert has_element?(view, "#settings-external-update[role='alert']")
    assert has_element?(view, "#settings-error-summary[role='alert']")
    assert has_element?(view, "#settings-max-tokens[value='0'][aria-invalid='true']")
    refute has_element?(view, "#settings-default-model[value='external-model-update']")

    view
    |> form("#settings-form", %{
      "settings" => %{"max_tokens" => "0", "default_model" => "continued-local-edit"}
    })
    |> render_change()

    assert has_element?(view, "#settings-external-update[role='alert']")
    assert has_element?(view, "#settings-default-model[value='continued-local-edit']")
  end
end
