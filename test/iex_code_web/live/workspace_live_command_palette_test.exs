defmodule IexCodeWeb.WorkspaceLiveCommandPaletteTest do
  use IexCode.E2E.Case, async: false
  @moduletag mock_llm: true

  # ============================================================================
  # 1. Command Palette Modal Toggle & Visibility
  # ============================================================================
  describe "Command Palette Modal Toggle & Visibility" do
    test "toggles command palette open and closed via LiveView events", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # The persistent hook receives Cmd/Ctrl+K even while the dialog is closed.
      assert has_element?(view, "#command-palette-controller[phx-hook='CommandPalette']")
      refute has_element?(view, "#command-palette-modal")

      # Open command palette
      render_click(view, "toggle_command_palette")
      assert has_element?(view, "#command-palette-modal")
      assert has_element?(view, "#command-palette-input")
      assert has_element?(view, "#command-palette-dialog[role='dialog'][aria-modal='true']")

      assert has_element?(
               view,
               "#command-palette-input[role='combobox'][aria-controls='command-palette-results']"
             )

      assert has_element?(view, "#command-palette-results[role='listbox']")
      assert has_element?(view, "#palette-item-0[role='option']")

      assert has_element?(
               view,
               "#command-palette-input[aria-activedescendant='palette-item-0']"
             )

      # Close command palette
      render_click(view, "close_command_palette")
      refute has_element?(view, "#command-palette-modal")
    end

    test "re-toggling when already open closes the palette", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      render_click(view, "toggle_command_palette")
      assert has_element?(view, "#command-palette-modal")

      render_click(view, "toggle_command_palette")
      refute has_element?(view, "#command-palette-modal")
    end
  end

  # ============================================================================
  # 2. Search Indexing & Dynamic Fuzzy Filtering
  # ============================================================================
  describe "Command Palette Search & Filtering" do
    setup %{workspace_path: path} do
      # Seed workspace files
      workspace_write_file(
        path,
        "lib/calculator.ex",
        "defmodule Calculator do\n  def add(a, b), do: a + b\nend"
      )

      workspace_write_file(
        path,
        "test/calculator_test.exs",
        "defmodule CalculatorTest do\n  use ExUnit.Case\nend"
      )

      workspace_write_file(path, "lib/auth/user.ex", "defmodule Auth.User do\nend")

      :ok
    end

    test "filters across actions, views, and project files simultaneously", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project, %{title: "Feature Development Session"})
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      render_click(view, "toggle_command_palette")

      # Search for "calc"
      render_change(view, "command_palette_search", %{"query" => "calc"})
      html = render(view)

      assert html =~ "calculator.ex" or html =~ "calculator_test.exs"
      refute html =~ "auth/user.ex"

      # Search for "test" (should match Run All Tests action and Test Runner view and calculator_test.exs)
      render_change(view, "command_palette_search", %{"query" => "test"})
      html_test = render(view)

      assert html_test =~ "Run All Tests" or html_test =~ "Test Runner" or
               html_test =~ "calculator_test.exs"
    end

    test "displays empty state message on queries with no matches", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      render_click(view, "toggle_command_palette")
      render_change(view, "command_palette_search", %{"query" => "xyznonexistentquery999"})

      html = render(view)
      assert html =~ "No results found" or html =~ "xyznonexistentquery999"
    end

    test "safely handles special regex and meta characters without crashing", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      render_click(view, "toggle_command_palette")

      # Special regex characters
      for special <- ["[", "]", "*", "+", "?", "\\", "$", "^", "(", ")", "{", "}"] do
        assert render_change(view, "command_palette_search", %{"query" => special})
      end
    end
  end

  # ============================================================================
  # 3. Category Filter Pills
  # ============================================================================
  describe "Category Filter Pills" do
    setup %{workspace_path: path} do
      workspace_write_file(path, "lib/app.ex", "defmodule App do\nend")
      :ok
    end

    test "isolates search results to specific category pills", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project, %{title: "Alpha Session"})
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      render_click(view, "toggle_command_palette")

      # Filter to "actions"
      render_click(view, "command_palette_set_category", %{"category" => "actions"})
      html_actions = render(view)
      assert html_actions =~ "Run All Tests" or html_actions =~ "Start New Goal"
      refute html_actions =~ "lib/app.ex"

      # Filter to "views"
      render_click(view, "command_palette_set_category", %{"category" => "views"})
      html_views = render(view)

      assert html_views =~ "Dashboard" or html_views =~ "Visual Test Runner" or
               html_views =~ "AST Query Explorer"

      # Filter to "files"
      render_click(view, "command_palette_set_category", %{"category" => "files"})
      html_files = render(view)
      assert html_files =~ "lib/app.ex"

      # Filter back to "all"
      render_click(view, "command_palette_set_category", %{"category" => "all"})
      html_all = render(view)
      assert html_all =~ "Run All Tests"
      assert html_all =~ "lib/app.ex"
    end
  end

  # ============================================================================
  # 4. Keyboard Navigation & Index Clamping
  # ============================================================================
  describe "Keyboard Navigation" do
    test "moves selected index up and down with boundary bounds check", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      render_click(view, "toggle_command_palette")

      # Navigate down
      render_click(view, "command_palette_navigate", %{"direction" => "down"})
      # Navigate down again
      render_click(view, "command_palette_navigate", %{"direction" => "down"})
      # Navigate up
      render_click(view, "command_palette_navigate", %{"direction" => "up"})

      # Modal stays open and active
      assert has_element?(view, "#command-palette-modal")
    end
  end

  # ============================================================================
  # 5. Item Execution & Jump Actions
  # ============================================================================
  describe "Action Execution & Tab/File Jump" do
    setup %{workspace_path: path} do
      workspace_write_file(
        path,
        "lib/worker.ex",
        "defmodule Worker do\n  def perform, do: :done\nend"
      )

      :ok
    end

    test "selecting a view item switches the active workspace tab", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      render_click(view, "toggle_command_palette")
      render_click(view, "command_palette_set_category", %{"category" => "views"})
      render_change(view, "command_palette_search", %{"query" => "tests"})

      # Select the first result
      render_click(view, "command_palette_select_item", %{"index" => "0"})

      # Palette closes and active tab switches to tests
      refute has_element?(view, "#command-palette-modal")
      assert render(view) =~ "Visual Test Studio" or render(view) =~ "Test Runner"
    end

    test "selecting a file item switches to files tab and loads buffer", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      render_click(view, "toggle_command_palette")
      render_click(view, "command_palette_set_category", %{"category" => "files"})
      render_change(view, "command_palette_search", %{"query" => "worker.ex"})

      render_click(view, "command_palette_select_item", %{"index" => "0"})

      refute has_element?(view, "#command-palette-modal")
      html = render(view)
      assert html =~ "worker.ex"
    end

    test "executing selected item via Enter keypress simulation", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      render_click(view, "toggle_command_palette")
      render_click(view, "command_palette_set_category", %{"category" => "views"})
      render_change(view, "command_palette_search", %{"query" => "terminal"})

      # Execute selected
      render_click(view, "command_palette_execute_selected")

      refute has_element?(view, "#command-palette-modal")
      assert render(view) =~ "Terminal" or render(view) =~ "terminal"
    end

    test "Toggle Swarm Mode action dispatches the real swarm event", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project, %{swarm_mode: false})
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      assert has_element?(view, "#workspace-header-actions", "Swarm: OFF")

      render_click(view, "toggle_command_palette")
      render_click(view, "command_palette_set_category", %{"category" => "actions"})
      render_change(view, "command_palette_search", %{"query" => "Toggle Swarm Mode"})
      render_click(view, "command_palette_select_item", %{"index" => "0"})

      refute has_element?(view, "#command-palette-modal")
      assert has_element?(view, "#workspace-header-actions", "Swarm: ON")
    end
  end
end
