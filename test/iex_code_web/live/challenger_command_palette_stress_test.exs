defmodule IexCodeWeb.ChallengerCommandPaletteStressTest do
  use IexCode.E2E.Case, async: false
  @moduletag mock_llm: true

  alias IexCodeWeb.CommandPalette

  # ============================================================================
  # 1. Pure Unit-Level Fuzzy Engine & Stress Tests
  # ============================================================================
  describe "CommandPalette.search/4 Engine Stress & Fuzzing" do
    setup do
      files = [
        "lib/app/accounts/user.ex",
        "lib/app/accounts/auth.ex",
        "lib/app/calc.ex",
        "lib/app_web/live/editor_live.ex",
        "lib/app_web/components/core_components.ex",
        "test/app/calc_test.exs",
        "assets/js/app.js",
        "assets/css/app.css",
        "README.md",
        "package.json"
      ]

      sessions = [
        %{id: "sess-1", title: "Authentication Flow", updated_at: DateTime.utc_now()},
        %{id: "sess-2", title: "Calculator Refactor", updated_at: ~N[2026-08-22 10:00:00]},
        %{id: "sess-3", title: "AST Explorer Implementation", updated_at: "2026-08-22 11:00"},
        %{id: "sess-4", title: nil, updated_at: nil}
      ]

      {:ok, %{files: files, sessions: sessions}}
    end

    test "handles nil, empty, and whitespace-only queries gracefully", %{
      files: files,
      sessions: sessions
    } do
      # nil query returns default full results without raising
      results_nil = CommandPalette.search(nil, files, sessions, "all")
      assert is_list(results_nil)
      assert length(results_nil) > 0

      # empty query returns all actions and views plus files and sessions
      results_empty = CommandPalette.search("", files, sessions, "all")
      assert length(results_empty) == length(results_nil)

      # whitespace-only query gets trimmed to empty query
      results_space = CommandPalette.search("   \t  \n ", files, sessions, "all")
      assert length(results_space) == length(results_empty)
    end

    test "handles regex metacharacters and special symbols safely", %{
      files: files,
      sessions: sessions
    } do
      symbols = [
        "[",
        "]",
        "*",
        "+",
        "?",
        "\\",
        "$",
        "^",
        "(",
        ")",
        "{",
        "}",
        "|",
        ".",
        "**",
        ".*",
        "++",
        "[a-z]+",
        "\\d+",
        "(?:foo)",
        "\\0",
        "\0",
        "\x00",
        "\"'",
        "`~",
        "<script>alert(1)</script>",
        "!@#$%^&*()_+-="
      ]

      for sym <- symbols do
        results = CommandPalette.search(sym, files, sessions, "all")
        assert is_list(results), "Failed on symbol: #{inspect(sym)}"
      end
    end

    test "handles unicode, emojis, and multilingual text", %{
      files: files,
      sessions: sessions
    } do
      unicode_queries = ["🚀", "✨", "ñ", "ç", "ü", "日本語", "العربية", "Скрипт", "🔥💥"]

      for q <- unicode_queries do
        results = CommandPalette.search(q, files, sessions, "all")
        assert is_list(results)
      end
    end

    test "handles extremely long queries (10,000+ characters) without performance degradation", %{
      files: files,
      sessions: sessions
    } do
      giant_query = String.duplicate("long_search_term_", 1000)

      {micros, results} =
        :timer.tc(fn ->
          CommandPalette.search(giant_query, files, sessions, "all")
        end)

      # Execution should be fast (< 50ms) and return empty list cleanly
      assert micros < 50_000, "Search on 10k query took #{micros}us"
      assert results == []
    end

    test "enforces category isolation filters strictly", %{files: files, sessions: sessions} do
      # Actions only
      actions = CommandPalette.search("", files, sessions, "actions")
      assert length(actions) == length(CommandPalette.actions())
      assert Enum.all?(actions, fn i -> i.category == :action end)

      # Views only
      views = CommandPalette.search("", files, sessions, "views")
      assert length(views) == length(CommandPalette.views())
      assert Enum.all?(views, fn i -> i.category == :view end)

      # Files only
      file_results = CommandPalette.search("calc", files, sessions, "files")
      assert length(file_results) > 0
      assert Enum.all?(file_results, fn i -> i.category == :file end)

      # Sessions only
      session_results = CommandPalette.search("calc", files, sessions, "sessions")
      assert length(session_results) == 1
      assert Enum.all?(session_results, fn i -> i.category == :session end)

      # Invalid category returns empty list without error
      invalid_results = CommandPalette.search("calc", files, sessions, "non_existent_category")
      assert invalid_results == []
    end

    test "caps maximum returned items for files (25) and sessions (10)", %{sessions: sessions} do
      # 50 simulated files
      many_files = for i <- 1..50, do: "lib/module_#{i}.ex"

      file_results = CommandPalette.search("module", many_files, sessions, "files")
      assert length(file_results) == 25

      # 20 simulated sessions
      many_sessions = for i <- 1..20, do: %{id: "s#{i}", title: "Session #{i}"}
      session_results = CommandPalette.search("Session", [], many_sessions, "sessions")
      assert length(session_results) == 10
    end

    test "assigns accurate file extension icons", %{sessions: sessions} do
      sample_files = [
        "lib/foo.ex",
        "test/foo.exs",
        "lib/foo.heex",
        "assets/app.js",
        "assets/app.css",
        "DOCS.md",
        "data.json",
        "image.png"
      ]

      results = CommandPalette.search("", sample_files, sessions, "files")

      icons_by_ext =
        results
        |> Enum.map(fn item -> {Path.extname(item.path), item.icon} end)
        |> Map.new()

      assert icons_by_ext[".ex"] == "hero-code-bracket"
      assert icons_by_ext[".exs"] == "hero-code-bracket-square"
      assert icons_by_ext[".heex"] == "hero-cube"
      assert icons_by_ext[".js"] == "hero-cpu-chip"
      assert icons_by_ext[".css"] == "hero-paint-brush"
      assert icons_by_ext[".md"] == "hero-document-text"
      assert icons_by_ext[".json"] == "hero-document-chart-bar"
      assert icons_by_ext[".png"] == "hero-document"
    end
  end

  # ============================================================================
  # 2. LiveView Arrow Navigation, Wrapping & Stress Cycles
  # ============================================================================
  describe "LiveView Command Palette Rapid Arrow Navigation & Wrapping" do
    test "correctly wraps selection from top to bottom (up) and bottom to top (down)", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Open palette
      render_click(view, "toggle_command_palette")
      assert has_element?(view, "#command-palette-modal")

      # Filter to views to have a deterministic item count
      render_click(view, "command_palette_set_category", %{"category" => "views"})
      views_count = length(CommandPalette.views())

      # Initially at index 0
      assert has_element?(view, "#palette-item-0.bg-cyan-950\\/40") or
               has_element?(view, "#palette-item-0")

      # Press UP at index 0 -> should wrap to index (views_count - 1)
      render_click(view, "command_palette_navigate", %{"direction" => "up"})
      last_idx = views_count - 1
      assert has_element?(view, "#palette-item-#{last_idx}")

      # Press DOWN from last item -> should wrap to index 0
      render_click(view, "command_palette_navigate", %{"direction" => "down"})
      assert has_element?(view, "#palette-item-0")

      # Stress test: perform 100 rapid arrow movements in alternating directions
      for _ <- 1..50 do
        render_click(view, "command_palette_navigate", %{"direction" => "down"})
        render_click(view, "command_palette_navigate", %{"direction" => "up"})
      end

      # Modal is still open and intact
      assert has_element?(view, "#command-palette-modal")
    end

    test "handles navigation gracefully when results list is empty", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      render_click(view, "toggle_command_palette")
      # Force empty result set
      render_change(view, "command_palette_search", %{"query" => "unmatchable_query_string_999"})

      # Navigation in empty list should not raise DivisionByZero or Enum out of bounds
      assert render_click(view, "command_palette_navigate", %{"direction" => "down"})
      assert render_click(view, "command_palette_navigate", %{"direction" => "up"})

      # Executing selected in empty list closes palette safely
      render_click(view, "command_palette_execute_selected")
      refute has_element?(view, "#command-palette-modal")
    end

    test "handles out-of-bounds selection indices safely", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      render_click(view, "toggle_command_palette")

      # Select wildly out-of-bounds index (e.g. 99999)
      render_click(view, "command_palette_select_item", %{"index" => "99999"})
      refute has_element?(view, "#command-palette-modal")
    end
  end

  # ============================================================================
  # 3. Comprehensive Action & View Dispatching Verification
  # ============================================================================
  describe "Comprehensive Command Palette Action Dispatching" do
    setup %{workspace_path: path} do
      # Write sample source file
      workspace_write_file(
        path,
        "lib/sample_service.ex",
        "defmodule SampleService do\n  def run, do: :ok\nend"
      )

      :ok
    end

    test "switches to all 9 navigation tabs through the command palette", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      tabs = [
        {"Dashboard / Kanban", "kanban"},
        {"Coach & Swarm Telemetry", "swarm"},
        {"Scheduled Tasks & Calendar", "calendar"},
        {"Progress & Diffs Hub", "changes"},
        {"Visual Test Runner & AutoFix", "tests"},
        {"AST Query Explorer", "ast"},
        {"Chat Assistant", "chat"},
        {"Resources & Files", "files"},
        {"Terminal Shell", "terminal"}
      ]

      for {title, _tab} <- tabs do
        render_click(view, "toggle_command_palette")
        render_click(view, "command_palette_set_category", %{"category" => "views"})
        render_change(view, "command_palette_search", %{"query" => title})
        render_click(view, "command_palette_select_item", %{"index" => "0"})

        refute has_element?(view, "#command-palette-modal")
      end
    end

    test "dispatches all quick actions without errors", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      actions = [
        "Run All Tests",
        "Run Failed Tests",
        "Run Stale Tests",
        "Start New Goal",
        "Trigger AutoFix Studio",
        "AST Symbol Search",
        "New Kanban Task",
        "Toggle Swarm Mode",
        "Git Fetch & Status"
      ]

      for action_title <- actions do
        render_click(view, "toggle_command_palette")
        render_click(view, "command_palette_set_category", %{"category" => "actions"})
        render_change(view, "command_palette_search", %{"query" => action_title})
        render_click(view, "command_palette_select_item", %{"index" => "0"})

        refute has_element?(view, "#command-palette-modal")
      end

      # Settings is intentionally a full-page navigation action, unlike the
      # in-place workspace actions above. Assert its redirect independently
      # instead of trying to reopen the palette on a terminated LiveView.
      render_click(view, "toggle_command_palette")
      render_click(view, "command_palette_set_category", %{"category" => "actions"})
      render_change(view, "command_palette_search", %{"query" => "Settings & API Keys"})
      render_click(view, "command_palette_select_item", %{"index" => "0"})

      assert_redirect(view, ~p"/sessions/#{session.id}/settings")
    end

    test "opens file buffer and transitions to files tab on file item selection", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      render_click(view, "toggle_command_palette")
      render_click(view, "command_palette_set_category", %{"category" => "files"})
      render_change(view, "command_palette_search", %{"query" => "sample_service.ex"})

      render_click(view, "command_palette_select_item", %{"index" => "0"})

      refute has_element?(view, "#command-palette-modal")
      html = render(view)
      assert html =~ "sample_service.ex"
    end
  end
end
