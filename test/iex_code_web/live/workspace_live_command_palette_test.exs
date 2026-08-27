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
    assert has_element?(view, "#command-palette-results", "No results found")
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

    render_change(view, "command_palette_search", %{"query" => "Terminal Shell"})
    render_click(view, "command_palette_execute_selected")

    refute has_element?(view, "#command-palette-modal")
    assert :sys.get_state(view.pid).socket.assigns.active_tab == "terminal"
  end

  test "palette dispatches a retained action", %{conn: conn, workspace_path: path} do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project, %{swarm_mode: false})
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    assert has_element?(view, "#workspace-header-actions", "Swarm: OFF")

    render_click(view, "toggle_command_palette")
    render_click(view, "command_palette_set_category", %{"category" => "actions"})
    render_change(view, "command_palette_search", %{"query" => "Toggle Swarm Mode"})
    render_click(view, "command_palette_select_item", %{"index" => "0"})

    assert has_element?(view, "#workspace-header-actions", "Swarm: ON")
  end
end
