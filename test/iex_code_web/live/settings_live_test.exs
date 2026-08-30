defmodule IexCodeWeb.SettingsLiveTest do
  use IexCode.E2E.Case, async: false

  alias IexCode.{Repo, Sessions, Settings}
  alias IexCode.Settings.AppSettings

  setup do
    previous_reader = Application.get_env(:iex_code, :runtime_status_reader)
    previous_snapshot = Application.get_env(:iex_code, :runtime_status_reader_stub)
    previous_terminal_timeout = Application.get_env(:iex_code, :terminal_idle_timeout_ms)
    previous_session_timeout = Application.get_env(:iex_code, :session_idle_timeout_ms)
    previous_output_config = Application.get_env(:iex_code, :output_artifacts)

    Application.put_env(:iex_code, :runtime_status_reader, IexCode.RuntimeStatusReaderStub)
    Application.put_env(:iex_code, :runtime_status_reader_stub, runtime_snapshot(:idle))

    on_exit(fn ->
      restore_env(:runtime_status_reader, previous_reader)
      restore_env(:runtime_status_reader_stub, previous_snapshot)
      restore_env(:terminal_idle_timeout_ms, previous_terminal_timeout)
      restore_env(:session_idle_timeout_ms, previous_session_timeout)
      restore_env(:output_artifacts, previous_output_config)
    end)

    :ok
  end

  test "global route renders every settings section and accessible save controls", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    assert has_element?(view, "#settings-page")
    assert has_element?(view, "#settings-form[phx-submit='save_settings']")
    assert has_element?(view, "#settings-return-workspace[href='/']")
    assert has_element?(view, "#settings-logout-form[action='/logout'][method='post']")

    for section <-
          ~w(models execution goals swarm research providers editor usage resources runtime) do
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

  test "calibration bench exposes shared chassis geometry and explicit theme controls", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/settings")
    document = view |> render() |> LazyHTML.from_fragment()

    assert has_element?(view, "#settings-page.settings-page.sf-ambient-field")
    assert has_element?(view, "#settings-calibration-bench.sf-chassis")

    assert has_element?(
             view,
             "form#settings-form[phx-change='validate_settings'][phx-submit='save_settings']"
           )

    assert Enum.count(LazyHTML.query(document, "#settings-calibration-bench.sf-chassis")) == 1
    assert Enum.count(LazyHTML.query(document, "form#settings-form")) == 1

    assert Enum.count(
             LazyHTML.query(
               document,
               "form#settings-logout-form[action='/logout'][method='post']"
             )
           ) == 1

    assert Enum.count(LazyHTML.query(document, "#settings-form #settings-save-bar")) == 1

    for section <-
          ~w(models execution goals swarm research providers editor usage resources runtime) do
      assert Enum.count(
               LazyHTML.query(document, "section##{section}[aria-labelledby='#{section}-title']")
             ) == 1

      assert Enum.count(LazyHTML.query(document, "##{section}-title")) == 1

      assert Enum.count(LazyHTML.query(document, "#settings-nav-#{section}[href='##{section}']")) ==
               1

      assert Enum.count(
               LazyHTML.query(document, "#settings-mobile-section-nav a[href='##{section}']")
             ) == 1
    end

    for {id, value, label} <- [
          {"settings-theme-dark", "dark", "Dark"},
          {"settings-theme-light", "light", "Light"},
          {"settings-theme-system", "system", "System"}
        ] do
      assert has_element?(
               view,
               "#settings-theme-controls ##{id}[type='button'][data-phx-theme='#{value}'][aria-pressed='false']",
               label
             )

      assert document
             |> LazyHTML.query("##{id}")
             |> LazyHTML.attribute("phx-click")
             |> List.first() == ~s([["dispatch",{"event":"phx:set-theme"}]])

      refute has_element?(view, "#settings-form ##{id}")
      refute has_element?(view, "##{id}[name]")
      refute has_element?(view, "##{id}[phx-value-theme]")
    end

    assert has_element?(
             view,
             "#settings-theme-controls[role='group'][aria-label='Theme preference']"
           )

    refute has_element?(view, "#settings-modal")

    view
    |> form("#settings-form", %{"settings" => %{"default_model" => "theme-safe-draft"}})
    |> render_change()

    assert has_element?(view, "#settings-default-model[value='theme-safe-draft']")
    assert has_element?(view, "#settings-client-behaviors[data-dirty='true']")
    assert has_element?(view, "#settings-save:not([disabled])")
    assert has_element?(view, "#settings-discard:not([disabled])")

    for id <- ~w(settings-theme-dark settings-theme-light settings-theme-system) do
      assert has_element?(view, "##{id}[type='button']")
    end
  end

  test "resource policy is editable with guarded advanced controls and read-only deployment facts",
       %{
         conn: conn
       } do
    {:ok, view, _html} = live(conn, ~p"/settings")

    assert has_element?(view, "#resources")
    assert has_element?(view, "#settings-resource-pressure[value='70']")
    assert has_element?(view, "#settings-resource-critical[value='85']")
    assert has_element?(view, "#settings-terminal-idle-timeout[value='30']")
    assert has_element?(view, "#settings-resource-advanced")
    assert has_element?(view, "#settings-output-artifact-limit[value='256']")
    assert has_element?(view, "#settings-output-spool-quota[value='2048']")
    assert has_element?(view, "#settings-output-retention[value='7']")
    assert has_element?(view, "#settings-deployment-limits", "Restart required")
    refute has_element?(view, "#settings-deployment-limits input")

    view
    |> form("#settings-form", %{
      "settings" => %{
        "resource_pressure_percent" => "72",
        "resource_critical_percent" => "88",
        "terminal_idle_timeout_minutes" => "25",
        "session_idle_timeout_minutes" => "40",
        "output_artifact_limit_mib" => "128",
        "output_spool_quota_mib" => "1536",
        "output_retention_days" => "10"
      }
    })
    |> render_submit()

    saved = Settings.get_settings()
    assert saved.resource_pressure_percent == 72
    assert saved.resource_critical_percent == 88
    assert saved.terminal_idle_timeout_minutes == 25
    assert saved.session_idle_timeout_minutes == 40
    assert saved.output_artifact_limit_mib == 128
    assert saved.output_spool_quota_mib == 1536
    assert saved.output_retention_days == 10
    assert Application.get_env(:iex_code, :terminal_idle_timeout_ms) == 25 * 60_000
  end

  test "resource policy rejects crossed thresholds and an undersized spool quota", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    view
    |> form("#settings-form", %{
      "settings" => %{
        "resource_pressure_percent" => "90",
        "resource_critical_percent" => "85",
        "output_artifact_limit_mib" => "512",
        "output_spool_quota_mib" => "256"
      }
    })
    |> render_submit()

    assert has_element?(view, "#settings-error-summary")
    assert has_element?(view, "#settings-resource-critical[aria-invalid='true']")
    assert has_element?(view, "#settings-output-spool-quota[aria-invalid='true']")
  end

  test "runtime panel renders activity, memory, and BEAM facts", %{conn: conn} do
    Application.put_env(:iex_code, :runtime_status_reader_stub, runtime_snapshot(:active))
    {:ok, view, _html} = live(conn, ~p"/settings")

    assert has_element?(view, "#settings-runtime-panel[data-state='active']")
    assert has_element?(view, "#settings-runtime-state[data-tone='active']", "Active")
    assert has_element?(view, "#settings-runtime-runs", "2 active · 3 queued · 8 capacity")
    assert has_element?(view, "#settings-runtime-agents", "4")
    assert has_element?(view, "#settings-runtime-fleets", "1")
    assert has_element?(view, "#settings-runtime-sessions", "6")
    assert has_element?(view, "#settings-runtime-terminals", "2")
    assert has_element?(view, "#settings-runtime-memory-container", "512 MiB / 1.0 GiB")
    assert has_element?(view, "#settings-runtime-beam-memory", "128 MiB")
    assert has_element?(view, "#settings-runtime-ports", "7 / 65536")
    assert has_element?(view, "#settings-runtime-memory-peak", "768 MiB")
    assert has_element?(view, "#settings-runtime-pids", "42 / 1024")
    assert has_element?(view, "#settings-runtime-oom", "3 events · 1 kills")
    assert has_element?(view, "#settings-runtime-pressure", "pressure")

    assert has_element?(
             view,
             "#settings-runtime-governor",
             "3 active · 1 interactive · 4 background queued"
           )

    assert has_element?(view, "#settings-runtime-dag-attempts", "5 active DAG attempts")
    refute has_element?(view, "#runtime input")
    refute has_element?(view, "#runtime select")
    refute has_element?(view, "#runtime textarea")
  end

  test "runtime refresh changes only telemetry and preserves a dirty settings draft", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/settings")

    view
    |> form("#settings-form", %{"settings" => %{"default_model" => "unsaved-runtime-draft"}})
    |> render_change()

    Application.put_env(:iex_code, :runtime_status_reader_stub, runtime_snapshot(:active))
    send(view.pid, :refresh_runtime_status)
    _ = :sys.get_state(view.pid)

    assert has_element?(view, "#settings-runtime-panel[data-state='active']")
    assert has_element?(view, "#settings-runtime-state[data-tone='active']", "Active")
    assert has_element?(view, "#settings-default-model[value='unsaved-runtime-draft']")
    assert has_element?(view, "#settings-save-status", "Unsaved changes")
    assert has_element?(view, "#settings-save:not([disabled])")
  end

  test "runtime refresh preserves an invalid settings draft and its navigation guard", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/settings")

    view
    |> form("#settings-form", %{"settings" => %{"max_tokens" => "0"}})
    |> render_submit()

    Application.put_env(:iex_code, :runtime_status_reader_stub, runtime_snapshot(:active))
    send(view.pid, :refresh_runtime_status)
    _ = :sys.get_state(view.pid)

    assert has_element?(view, "#settings-runtime-panel[data-state='active']")
    assert has_element?(view, "#settings-max-tokens[value='0'][aria-invalid='true']")
    assert has_element?(view, "#settings-error-summary[role='alert']")
    assert has_element?(view, "#settings-client-behaviors[data-dirty='true']")
    assert has_element?(view, "#settings-return-workspace[data-unsaved-confirm]")
  end

  test "runtime reader failures render unavailable facts without crashing the LiveView", %{
    conn: conn
  } do
    Application.put_env(:iex_code, :runtime_status_reader_stub, :raise)
    {:ok, view, _html} = live(conn, ~p"/settings")

    assert has_element?(view, "#settings-page")
    assert has_element?(view, "#settings-runtime-panel[data-state='unavailable']")

    assert has_element?(
             view,
             "#settings-runtime-state[data-tone='unavailable']",
             "Unavailable"
           )

    assert has_element?(view, "#settings-runtime-runs", "Unavailable")
    assert has_element?(view, "#settings-runtime-memory-container", "Unavailable")
    assert has_element?(view, "#settings-runtime-ports", "Unavailable")
  end

  test "malformed runtime snapshots render unavailable facts instead of a false idle state", %{
    conn: conn
  } do
    malformed_snapshot =
      :idle
      |> runtime_snapshot()
      |> put_in([:dispatcher, :active], nil)

    Application.put_env(:iex_code, :runtime_status_reader_stub, malformed_snapshot)
    {:ok, view, _html} = live(conn, ~p"/settings")

    assert has_element?(view, "#settings-page")
    assert has_element?(view, "#settings-runtime-panel[data-state='unavailable']")

    assert has_element?(
             view,
             "#settings-runtime-state[data-tone='unavailable']",
             "Unavailable"
           )

    assert has_element?(view, "#settings-runtime-runs", "Unavailable")
    assert has_element?(view, "#settings-runtime-memory-container", "Unavailable")
    assert has_element?(view, "#settings-runtime-ports", "Unavailable")
  end

  test "a canonical unavailable snapshot with nil measurements remains unavailable", %{conn: conn} do
    unavailable_snapshot = %{
      state: :unavailable,
      container: %{memory_current_bytes: nil, memory_limit_bytes: nil},
      beam: %{memory_total_bytes: nil, port_count: nil, port_limit: nil},
      dispatcher: %{active: nil, queued: nil, capacity: nil},
      activity: %{
        agents: nil,
        fleets: nil,
        sessions: nil,
        terminals: nil,
        dag_attempts: nil
      }
    }

    Application.put_env(:iex_code, :runtime_status_reader_stub, unavailable_snapshot)
    {:ok, view, _html} = live(conn, ~p"/settings")

    assert has_element?(view, "#settings-runtime-panel[data-state='unavailable']")
    assert has_element?(view, "#settings-runtime-runs", "Unavailable")
    assert has_element?(view, "#settings-runtime-memory-container", "Unavailable")
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

  defp runtime_snapshot(state) do
    work_counts =
      if state == :active,
        do: %{active: 2, queued: 3, agents: 4, fleets: 1, dag_attempts: 5},
        else: %{active: 0, queued: 0, agents: 0, fleets: 0, dag_attempts: 0}

    %{
      state: state,
      container: %{
        memory_current_bytes: 512 * 1_048_576,
        memory_peak_bytes: 768 * 1_048_576,
        memory_limit_bytes: 1_073_741_824,
        oom_events: 3,
        oom_kill_events: 1,
        pids_current: 42,
        pids_limit: 1_024
      },
      beam: %{memory_total_bytes: 128 * 1_048_576, port_count: 7, port_limit: 65_536},
      dispatcher: %{active: work_counts.active, queued: work_counts.queued, capacity: 8},
      activity: %{
        agents: work_counts.agents,
        fleets: work_counts.fleets,
        sessions: 6,
        terminals: 2,
        dag_attempts: work_counts.dag_attempts
      },
      governor: %{
        state: :pressure,
        reserved_bytes: 128 * 1_048_576,
        active_tickets: 3,
        queued_interactive: 1,
        queued_background: 4
      },
      deployment: %{
        profile: "throughput",
        memory_limit_mib: 2_560,
        memory_reservation_mib: 512,
        pids_limit: 1_024,
        nofile_limit: 65_536
      }
    }
  end

  defp restore_env(key, nil), do: Application.delete_env(:iex_code, key)
  defp restore_env(key, value), do: Application.put_env(:iex_code, key, value)
end
