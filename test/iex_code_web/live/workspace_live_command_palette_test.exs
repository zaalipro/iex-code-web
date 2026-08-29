defmodule IexCodeWeb.WorkspaceLiveCommandPaletteTest do
  use IexCode.E2E.Case, async: false

  @moduletag mock_llm: true

  test "palette searches actions, views, and sessions without indexing project files", %{
    conn: conn,
    workspace_path: path
  } do
    workspace_write_file(path, "lib/palette_only_file.ex", "defmodule PaletteOnlyFile, do: :ok\n")
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project, %{title: "Release Planning"})
    _other = create_session_fixture(project, %{title: "Payments Refactor"})
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    assert has_element?(view, "#command-palette-controller[phx-hook='CommandPalette']")
    refute has_element?(view, "#command-palette-modal")
    refute has_element?(view, "#sidebar-tab-tests")
    refute has_element?(view, "#sidebar-tab-ast")
    refute has_element?(view, "#tab-btn-tests")
    refute has_element?(view, "#tab-btn-ast")
    refute has_element?(view, "#test-runner-panel")
    refute has_element?(view, "#ast-explorer-panel")

    render_click(view, "toggle_command_palette")

    assert has_element?(view, "#command-palette-dialog[role='dialog'][aria-modal='true']")
    assert has_element?(view, "#command-palette-input[role='combobox']")
    assert has_element?(view, "button[phx-value-category='actions']")
    assert has_element?(view, "button[phx-value-category='views']")
    assert has_element?(view, "button[phx-value-category='sessions']")
    refute has_element?(view, "button[phx-value-category='files']")

    render_change(view, "command_palette_search", %{"query" => "palette_only_file"})
    assert has_element?(view, "#command-palette-results", "No matching switchboard controls")
    refute has_element?(view, "#command-palette-results", "palette_only_file.ex")

    render_click(view, "command_palette_set_category", %{"category" => "sessions"})
    render_change(view, "command_palette_search", %{"query" => "Payments Refactor"})
    assert has_element?(view, "#command-palette-results", "Payments Refactor")

    render_click(view, "close_command_palette")
    refute has_element?(view, "#command-palette-modal")
  end

  test "palette navigation wraps and a view selection switches tabs", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    render_click(view, "toggle_command_palette")
    render_click(view, "command_palette_set_category", %{"category" => "views"})
    render_click(view, "command_palette_navigate", %{"direction" => "up"})
    assert has_element?(view, "#command-palette-modal")

    render_change(view, "command_palette_search", %{"query" => "Terminal Scope"})
    view |> element("[data-palette-item-id='view_terminal']") |> render_click()

    refute has_element?(view, "#command-palette-modal")
    assert :sys.get_state(view.pid).socket.assigns.active_tab == "terminal"
  end

  test "palette dispatches a retained action", %{conn: conn, workspace_path: path} do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project, %{swarm_mode: false})
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    refute :sys.get_state(view.pid).socket.assigns.session.swarm_mode

    render_click(view, "toggle_command_palette")
    render_click(view, "command_palette_set_category", %{"category" => "actions"})
    render_change(view, "command_palette_search", %{"query" => "Toggle Swarm Mode"})
    render_click(view, "command_palette_select_item", %{"index" => "0"})

    assert :sys.get_state(view.pid).socket.assigns.session.swarm_mode
  end

  test "switchboard exposes the closed instrument and group inventory", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project, %{title: "Release Planning"})
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    view |> element("#all-instruments-trigger") |> render_click()

    for id <-
          ~w(view_swarm view_kanban view_research view_calendar view_changes view_chat view_files view_terminal all-instruments new-project new-session settings-models settings-execution settings-research settings-runtime account-sign-out) do
      assert has_element?(view, "[data-palette-item-id='#{id}']")
    end

    assert has_element?(
             view,
             "#command-palette-dialog[data-sheet-close-event='close_command_palette'][data-sheet-return-id='command-palette-trigger'][data-sheet-background-id='workspace-shell']"
           )

    refute has_element?(view, "#workspace-sidebar")
    refute has_element?(view, "#workspace-desktop-tabs")
  end

  test "palette selection indices are bounded and malformed input is a no-op", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project, %{swarm_mode: false})
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    for index <- ["-1", "bad", "999999999999999999999999999999", "999"] do
      render_click(view, "toggle_command_palette")
      render_click(view, "command_palette_select_item", %{"index" => index})
      assert :sys.get_state(view.pid).socket.assigns.show_command_palette
      refute :sys.get_state(view.pid).socket.assigns.session.swarm_mode
      render_click(view, "close_command_palette")
    end
  end

  test "profile trigger resets the palette to settings and account", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    view |> element("#profile-settings-trigger") |> render_click()
    assert :sys.get_state(view.pid).socket.assigns.command_palette_category == "settings_account"
    assert has_element?(view, "[data-palette-item-id='settings-models']")
    assert has_element?(view, "[data-palette-item-id='account-sign-out']")
    refute has_element?(view, "[data-palette-item-id='view_swarm']")

    render_click(view, "close_command_palette")
    view |> element("#command-palette-trigger") |> render_click()
    assert :sys.get_state(view.pid).socket.assigns.command_palette_category == "all"
    assert has_element?(view, "[data-palette-item-id='view_swarm']")
  end

  test "searches authorized projects including a project with no session", %{
    conn: conn,
    workspace_path: path
  } do
    current = create_project_fixture(%{name: "Current Workspace", root_path: path})
    session = create_session_fixture(current)
    other_root = Path.join(System.tmp_dir!(), "palette-project-#{Ecto.UUID.generate()}")
    File.mkdir_p!(other_root)
    other = create_project_fixture(%{name: "Unattached Workspace", root_path: other_root})
    long_name = String.duplicate("v", 200)

    _long =
      create_project_fixture(%{
        name: long_name,
        root_path: Path.join(System.tmp_dir!(), Ecto.UUID.generate())
      })

    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
    render_click(view, "toggle_command_palette", %{"category" => "projects"})
    render_change(view, "command_palette_search", %{"query" => "Unattached"})

    assert has_element?(view, "[data-palette-item-id='project-#{other.id}']")
    refute has_element?(view, "[data-palette-item-id='project-#{other.id}']", other_root)

    view |> element("[data-palette-item-id='project-#{other.id}']") |> render_click()
    replacement = hd(IexCode.Sessions.list_sessions_for_project(other.id))
    assert_patch(view, "/sessions/#{replacement.id}")
    File.rm_rf(other_root)
  end

  test "delete confirmation rows remain searchable independently of session title", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project, %{title: "Keep this title"})
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    render_click(view, "toggle_command_palette", %{"category" => "sessions"})
    render_change(view, "command_palette_search", %{"query" => "Delete"})

    assert has_element?(
             view,
             "[data-palette-item-id='delete-session-#{session.id}'][data-confirm='Delete Keep this title? This cannot be undone.']"
           )
  end

  test "settings and logout rows are trusted route/form controls", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    render_click(view, "toggle_command_palette", %{"category" => "settings_account"})

    for {id, anchor} <- [
          {"settings-models", "models"},
          {"settings-execution", "execution"},
          {"settings-research", "research"},
          {"settings-runtime", "runtime"}
        ] do
      assert has_element?(
               view,
               "[data-palette-item-id='#{id}'][data-palette-href='/sessions/#{session.id}/settings##{anchor}']"
             )
    end

    html = render(view)
    assert has_element?(view, "#workspace-logout-form[action='/logout'][method='post']")
    assert has_element?(view, "#workspace-logout-form input[name='_csrf_token']")

    refute html =~ "workspace-logout-form[href"
  end
end
