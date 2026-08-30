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

    for hidden <- ["open_goal_modal", "start_goal"] do
      render_change(view, "command_palette_search", %{"query" => hidden})
      refute has_element?(view, "[data-palette-item-id='start_goal']")
    end

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
    assert has_element?(view, "#new-session-btn[type='button']")
    assert has_element?(view, "#new-session-btn", "New Session")
  end

  test "server result order, rendered option order, and arrow selection stay identical", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
    render_click(view, "toggle_command_palette")

    expected = Enum.map(:sys.get_state(view.pid).socket.assigns.command_palette_results, & &1.id)

    rendered =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#command-palette-results [data-palette-item-id]")
      |> Enum.map(&(&1 |> LazyHTML.attribute("data-palette-item-id") |> List.first()))

    assert rendered == expected

    render_click(view, "command_palette_navigate", %{"direction" => "down"})
    assert :sys.get_state(view.pid).socket.assigns.command_palette_selected_index == 1
    assert has_element?(view, "#command-palette-input[aria-activedescendant='palette-item-1']")
    assert has_element?(view, "#palette-item-1[aria-selected='true']")
  end

  test "all instruments remains selectable when it is the only query match", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}?view=terminal")

    render_click(view, "toggle_command_palette")
    render_change(view, "command_palette_search", %{"query" => "All instruments"})

    assert has_element?(view, "#palette-item-0[data-palette-item-id='all-instruments']")
    assert has_element?(view, "#command-palette-input[aria-activedescendant='palette-item-0']")
    view |> element("#palette-item-0") |> render_click()
    assert_patch(view, "/sessions/#{session.id}")
  end

  test "server-owned palette Fetch executes outside Changes", %{
    conn: conn,
    workspace_path: path
  } do
    parent = Path.dirname(path)
    suffix = System.unique_integer([:positive])
    origin = Path.join(parent, "palette-origin-#{suffix}.git")
    publisher = Path.join(parent, "palette-publisher-#{suffix}")

    on_exit(fn ->
      File.rm_rf(origin)
      File.rm_rf(publisher)
    end)

    {_, 0} = System.cmd("git", ["init", "--bare", "--initial-branch=main", origin])
    {_, 0} = System.cmd("git", ["init", "-b", "main"], cd: path)
    {_, 0} = System.cmd("git", ["config", "user.name", "Palette Client"], cd: path)
    {_, 0} = System.cmd("git", ["config", "user.email", "client@example.com"], cd: path)
    workspace_write_file(path, "README.md", "client head\n")
    {_, 0} = System.cmd("git", ["add", "README.md"], cd: path)
    {_, 0} = System.cmd("git", ["commit", "-m", "Initial"], cd: path)
    {_, 0} = System.cmd("git", ["remote", "add", "origin", origin], cd: path)
    {_, 0} = System.cmd("git", ["push", "-u", "origin", "main"], cd: path)
    {_, 0} = System.cmd("git", ["fetch", "origin"], cd: path)
    {old_remote, 0} = System.cmd("git", ["rev-parse", "refs/remotes/origin/main"], cd: path)
    {client_head, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: path)
    old_remote = String.trim(old_remote)
    client_head = String.trim(client_head)
    assert old_remote == client_head

    {_, 0} = System.cmd("git", ["clone", origin, publisher])
    {_, 0} = System.cmd("git", ["config", "user.name", "Palette Publisher"], cd: publisher)
    {_, 0} = System.cmd("git", ["config", "user.email", "publisher@example.com"], cd: publisher)
    File.write!(Path.join(publisher, "remote.txt"), "remote update\n")
    {_, 0} = System.cmd("git", ["add", "remote.txt"], cd: publisher)
    {_, 0} = System.cmd("git", ["commit", "-m", "Remote update"], cd: publisher)
    {_, 0} = System.cmd("git", ["push", "origin", "main"], cd: publisher)
    {new_remote, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: publisher)
    new_remote = String.trim(new_remote)
    refute new_remote == old_remote

    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    # A forged public event is not the private palette dispatch.
    render_click(view, "git_fetch", %{"source" => "palette"})
    {still_old, 0} = System.cmd("git", ["rev-parse", "refs/remotes/origin/main"], cd: path)
    assert String.trim(still_old) == old_remote

    render_click(view, "toggle_command_palette")
    render_change(view, "command_palette_search", %{"query" => "Git Fetch and Status"})
    assert has_element?(view, "#palette-item-0[data-palette-item-id='git_fetch']")
    view |> element("#palette-item-0") |> render_click()

    {fetched_remote, 0} =
      System.cmd("git", ["rev-parse", "refs/remotes/origin/main"], cd: path)

    {head_after, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: path)
    assert String.trim(fetched_remote) == new_remote
    assert String.trim(head_after) == client_head
    assert File.read!(Path.join(path, "README.md")) == "client head\n"
    refute File.exists?(Path.join(path, "remote.txt"))
    refute has_element?(view, "#command-palette-dialog")
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
             "[data-palette-item-id='delete-session-#{session.id}']"
           )

    refute has_element?(
             view,
             "[data-palette-item-id='delete-session-#{session.id}'][data-confirm]"
           )

    render_change(view, "command_palette_search", %{"query" => session.id})
    refute has_element?(view, "[data-palette-item-id='delete-session-#{session.id}']")
  end

  test "switchboard materials are theme-token driven", %{conn: conn, workspace_path: path} do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
    render_click(view, "toggle_command_palette")

    assert has_element?(view, "#command-palette-dialog.sf-chassis")
    assert has_element?(view, "#command-palette-input.min-h-11")

    source = File.read!("lib/iex_code_web/components/workspace_components.ex")
    [palette_source | _] = source |> String.split("def command_palette", parts: 2) |> tl()
    palette_source = palette_source |> String.split("defp palette_groups", parts: 2) |> hd()
    refute palette_source =~ ~r/#[0-9a-fA-F]{6}/
    refute palette_source =~ "gradient"
  end

  test "account selection uses the native logout form seam", %{conn: conn, workspace_path: path} do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    render_click(view, "toggle_command_palette", %{"category" => "settings_account"})

    index =
      view.pid
      |> :sys.get_state()
      |> get_in([Access.key!(:socket), Access.key!(:assigns), :command_palette_results])
      |> Enum.find_index(&(&1.id == "account-sign-out"))

    render_click(view, "command_palette_select_item", %{"index" => index})
    assert_push_event(view, "palette_submit_logout", %{})
    assert has_element?(view, "#workspace-logout-form[action='/logout'][method='post']")
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
    assert has_element?(view, "#workspace-logout-form-button.sf-control.min-h-11[type='submit']")

    refute html =~ "workspace-logout-form[href"
  end
end
