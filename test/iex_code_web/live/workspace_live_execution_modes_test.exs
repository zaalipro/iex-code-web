defmodule IexCodeWeb.WorkspaceLiveExecutionModesTest do
  use IexCode.E2E.Case, async: false

  alias IexCode.{Runs, Settings}

  test "/goal and /goal --draft use the canonical durable goal intake", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    view
    |> form("#prompt-form", %{"prompt" => "/goal Ship a bounded parser with tests"})
    |> render_submit()

    [queued] = Runs.list_runs(session_id: session.id)
    assert queued.kind == "coding_swarm"
    assert queued.mode == "swarm"
    assert queued.metadata["source"] == "autonomous_goal"
    assert queued.metadata["goal_title"] == "Ship a bounded parser with tests"
    assert queued.metadata["execution_policy"]["version"] == 1
    assert queued.metadata["execution_policy"]["swarm_agent_count"] == 4
    assert is_binary(queued.request_key)

    view
    |> form("#prompt-form", %{"prompt" => "/goal --draft Review the migration plan"})
    |> render_submit()

    draft =
      session.id
      |> then(&Runs.list_runs(session_id: &1))
      |> Enum.find(&(&1.status == "draft"))

    assert draft
    assert draft.metadata["goal_auto_start"] == false
    assert has_element?(view, "#flash-info", "will not start until you choose Start")
    render_click(view, "switch_tab", %{"tab" => "swarm"})
    assert has_element?(view, "#async-run-#{draft.id}")
  end

  test "ordinary durable prompts honor the configured single-agent default", %{
    conn: conn,
    workspace_path: path
  } do
    assert {:ok, _settings} =
             Settings.update_settings(%{
               default_dispatch_mode: "background",
               default_run_mode: "single",
               agent_max_turns: 7
             })

    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    view
    |> form("#prompt-form", %{"prompt" => "Inspect the failing parser and propose a fix"})
    |> render_submit()

    [run] = Runs.list_runs(session_id: session.id)
    assert run.kind == "coding_agent"
    assert run.mode == "single"
    assert run.metadata["execution_policy"]["agent_max_turns"] == 7
    render_click(view, "switch_tab", %{"tab" => "swarm"})
    assert has_element?(view, "#async-run-#{run.id}")
  end

  test "Chat tab preserves the configured Background dispatch default", %{
    conn: conn,
    workspace_path: path
  } do
    assert {:ok, _settings} =
             Settings.update_settings(%{
               default_dispatch_mode: "background",
               default_run_mode: "single"
             })

    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    assert has_element?(view, "#dispatch-mode-background[aria-pressed='true']")
    assert has_element?(view, "#dispatch-mode-interactive[aria-pressed='false']")

    render_click(view, "switch_tab", %{"tab" => "chat"})

    assert has_element?(view, "#mission-strip[data-active-view='chat']")
    assert has_element?(view, "#dispatch-mode-background[aria-pressed='true']")
    assert has_element?(view, "#dispatch-mode-interactive[aria-pressed='false']")

    view
    |> form("#prompt-form", %{"prompt" => "Inspect this module in the background"})
    |> render_submit()

    assert [%{kind: "coding_agent", mode: "single"}] =
             Runs.list_runs(session_id: session.id)
  end

  test "explicit dispatch selection remains stable across workspace tabs", %{
    conn: conn,
    workspace_path: path
  } do
    assert {:ok, _settings} =
             Settings.update_settings(%{default_dispatch_mode: "background"})

    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    view |> element("#dispatch-mode-interactive") |> render_click()
    assert has_element?(view, "#dispatch-mode-interactive[aria-pressed='true']")

    render_click(view, "switch_tab", %{"tab" => "chat"})
    assert has_element?(view, "#dispatch-mode-interactive[aria-pressed='true']")

    render_click(view, "switch_tab", %{"tab" => "swarm"})
    assert has_element?(view, "#dispatch-mode-interactive[aria-pressed='true']")

    view |> element("#dispatch-mode-background") |> render_click()
    render_click(view, "switch_tab", %{"tab" => "files"})

    assert has_element?(view, "#dispatch-mode-background[aria-pressed='true']")
    assert has_element?(view, "#dispatch-mode-interactive[aria-pressed='false']")
  end

  test "run setup stays scrollable on short viewports and disables irrelevant providers", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    view |> element("#toggle-run-setup") |> render_click()

    assert has_element?(view, "#prompt-composer[class*='overflow-y-auto']")
    assert has_element?(view, "#run-setup-panel[class*='overflow-y-auto']")
    assert has_element?(view, "#run-setup-providers[disabled][aria-disabled='true']")

    view
    |> form("#run-setup-panel", %{"run_setup" => %{"mode" => "research"}})
    |> render_change()

    refute has_element?(view, "#run-setup-providers[disabled]")
    assert has_element?(view, "#run-setup-providers[aria-disabled='false']")
  end

  test "explicit slash commands are boundary-safe and override interactive dispatch", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    view |> element("#dispatch-mode-interactive") |> render_click()

    html =
      view
      |> form("#prompt-form", %{"prompt" => "/swarming must not prefix-match"})
      |> render_submit()

    assert html =~ "Unknown command"
    assert Runs.list_runs(session_id: session.id) == []

    view
    |> form("#prompt-form", %{"prompt" => "/swarm Audit the durable ownership boundary"})
    |> render_submit()

    [run] = Runs.list_runs(session_id: session.id)
    assert run.kind == "coding_swarm"
    assert run.mode == "swarm"
  end

  test "/goal without an objective opens the reviewed goal form", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    view |> form("#prompt-form", %{"prompt" => "/goal"}) |> render_submit()

    assert has_element?(view, "#goal-modal")
    assert has_element?(view, "#goal-create-form")
    assert Runs.list_runs(session_id: session.id) == []
  end

  test "goal form reflects the configured draft default and submits a draft", %{
    conn: conn,
    workspace_path: path
  } do
    assert {:ok, _settings} = Settings.update_settings(%{goal_auto_start: false})

    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    view |> form("#prompt-form", %{"prompt" => "/goal"}) |> render_submit()

    assert has_element?(view, "#goal-auto-start")
    refute has_element?(view, "#goal-auto-start[checked]")

    view
    |> form("#goal-create-form", %{
      "goal" => %{
        "title" => "Review this goal before execution",
        "description" => "The global default must survive the modal boundary"
      }
    })
    |> render_submit()

    assert [draft] = Runs.list_runs(session_id: session.id)
    assert draft.status == "draft"
    assert draft.metadata["goal_auto_start"] == false
  end

  test "explicit /chat stays interactive when durable research setup is selected", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    view |> element("#toggle-run-setup") |> render_click()

    view
    |> form("#run-setup-panel", %{
      "run_setup" => %{
        "mode" => "research",
        "providers" => %{"duckduckgo" => "true"}
      }
    })
    |> render_change()

    view
    |> form("#prompt-form", %{"prompt" => "/chat Explain the current execution mode"})
    |> render_submit()

    assert Runs.list_runs(session_id: session.id) == []
  end

  test "explicit /ask stays interactive when typed DAG setup is selected", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    view |> element("#toggle-run-setup") |> render_click()

    view
    |> form("#run-setup-panel", %{"run_setup" => %{"mode" => "dag"}})
    |> render_change()

    view
    |> form("#prompt-form", %{"prompt" => "/ask Summarize the selected DAG policy"})
    |> render_submit()

    assert Runs.list_runs(session_id: session.id) == []
  end

  test "run setup snapshots per-run single-agent and swarm execution limits", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    view |> element("#toggle-run-setup") |> render_click()

    view
    |> form("#run-setup-panel", %{
      "run_setup" => %{
        "mode" => "single",
        "agent_max_turns" => "14",
        "swarm_agent_count" => "9",
        "swarm_max_retries" => "5"
      }
    })
    |> render_change()

    assert has_element?(view, "#run-setup-agent-max-turns[value='14']")
    assert has_element?(view, "#run-setup-swarm-agent-count[value='9']")
    assert has_element?(view, "#run-setup-swarm-max-retries[value='5']")

    view
    |> form("#prompt-form", %{"prompt" => "/run Inspect the execution loop"})
    |> render_submit()

    view
    |> form("#prompt-form", %{"prompt" => "/swarm Verify the fleet topology"})
    |> render_submit()

    runs = Runs.list_runs(session_id: session.id)
    single = Enum.find(runs, &(&1.kind == "coding_agent"))
    swarm = Enum.find(runs, &(&1.kind == "coding_swarm"))

    assert single.metadata["execution_policy"]["agent_max_turns"] == 14
    assert swarm.metadata["execution_policy"]["swarm_agent_count"] == 9
    assert swarm.metadata["execution_policy"]["swarm_max_retries"] == 5
  end

  test "invalid run setup values are preserved and block launch instead of being clamped", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    view |> element("#toggle-run-setup") |> render_click()

    view
    |> form("#run-setup-panel", %{
      "run_setup" => %{"max_attempts" => "99", "swarm_agent_count" => "2"}
    })
    |> render_change()

    assert has_element?(view, "#run-setup-policy-error[role='alert']")
    assert has_element?(view, "#run-setup-max-attempts[value='99']")

    html =
      view
      |> form("#prompt-form", %{"prompt" => "/swarm This must not launch with altered limits"})
      |> render_submit()

    assert html =~ "Fix Run setup before queueing work"
    assert Runs.list_runs(session_id: session.id) == []

    view
    |> form("#run-setup-panel", %{
      "run_setup" => %{"max_attempts" => "6", "swarm_agent_count" => "8"}
    })
    |> render_change()

    refute has_element?(view, "#run-setup-policy-error")

    view
    |> form("#prompt-form", %{"prompt" => "/swarm Launch with reviewed limits"})
    |> render_submit()

    assert [run] = Runs.list_runs(session_id: session.id)
    assert run.max_attempts == 6
    assert run.metadata["execution_policy"]["swarm_agent_count"] == 8
  end
end
