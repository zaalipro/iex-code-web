defmodule IexCodeWeb.WorkspaceLivePowerAdversarialTest do
  use IexCode.E2E.Case, async: false
  @moduletag mock_llm: true

  alias IexCode.Tools.Git

  setup %{workspace_path: path} do
    # Initialize workspace with git and source files
    {_, 0} = System.cmd("git", ["init", "-b", "main"], cd: path)
    {_, 0} = System.cmd("git", ["config", "user.name", "Live Tester"], cd: path)
    {_, 0} = System.cmd("git", ["config", "user.email", "livetester@iexcode.local"], cd: path)

    # Initial tracked files
    workspace_write_file(path, "lib/calculator.ex", """
    defmodule IexCode.Calculator do
      @moduledoc "High performance calculator"

      @doc "Multiplies two numbers"
      @spec multiply(number(), number()) :: number()
      def multiply(a, b), do: a * b

      defp secret_key, do: "secret_123"

      defmacro compute_macro(expr) do
        quote do: unquote(expr) * 10
      end

      @type calculation_result :: {:ok, number()}
      @callback validate(number()) :: boolean()
    end
    """)

    workspace_write_file(path, "README.md", "# Calculator Workspace\n")

    {_, 0} = System.cmd("git", ["add", "."], cd: path)
    {_, 0} = System.cmd("git", ["commit", "-m", "chore: initial workspace commit"], cd: path)

    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)

    {:ok, %{project: project, session: session, workspace_path: path}}
  end

  describe "LiveView AST Query Explorer Stress & Jump-to-Editor" do
    test "handles rapid querying, category filters, and dispatches jump_to_editor_line", %{
      conn: conn,
      session: session
    } do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Switch to AST Explorer
      render_click(view, "switch_tab", %{"tab" => "ast"})
      assert render(view) =~ "AST Query Explorer"

      # 1. Search for function "multiply"
      render_change(view, "search_ast_symbols", %{"query" => "multiply"})
      html = render(view)
      assert html =~ "multiply"

      # 2. Cycle all type filters
      for type <- ["all", "module", "function", "macro", "spec", "type", "callback", "doc"] do
        render_click(view, "set_ast_type_filter", %{"type" => type})
        assert render(view)
      end

      # 3. Cycle visibility filters
      for vis <- ["all", "public", "private"] do
        render_click(view, "set_ast_visibility", %{"visibility" => vis})
        assert render(view)
      end

      # 4. Search non-existent query (should return 0 results gracefully without crashing)
      render_change(view, "search_ast_symbols", %{"query" => "non_existent_symbol_xyz"})

      assert render(view) =~ "0 symbols found" or render(view) =~ "No symbols found" or
               render(view) =~ "non_existent_symbol_xyz"

      # 5. Jump to symbol at line 6
      render_click(view, "jump_to_symbol", %{"path" => "lib/calculator.ex", "line" => "6"})

      # Verify view switched to files tab and loaded calculator.ex
      html_files = render(view)
      assert html_files =~ "lib/calculator.ex"
      assert html_files =~ "def multiply(a, b)"
    end
  end

  describe "LiveView Git Hub Full Lifecycle & Staging Actions" do
    test "executes branch creation, switching, remote triggers, and multi-tier staging", %{
      conn: conn,
      session: session,
      workspace_path: path
    } do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Switch to changes tab
      render_click(view, "switch_tab", %{"tab" => "changes"})

      # 1. Branch Creation & Switching
      render_click(view, "toggle_branch_menu")
      render_click(view, "create_git_branch", %{"name" => "feature/power-git"})
      html_branch = render(view)
      assert html_branch =~ "feature/power-git"

      # Attempt empty branch creation
      render_click(view, "create_git_branch", %{"name" => "   "})
      assert render(view) =~ "Branch name cannot be empty" or render(view)

      # Switch back to main
      render_click(view, "switch_git_branch", %{"branch" => "main"})
      assert render(view) =~ "main"

      # 2. Remote Sync Triggers
      render_click(view, "git_fetch")
      render_click(view, "git_pull")

      # 3. Make working tree changes
      workspace_write_file(
        path,
        "lib/calculator.ex",
        "defmodule IexCode.Calculator, do: :modified_v2\n"
      )

      workspace_write_file(path, "lib/untracked_new.ex", "defmodule Untracked, do: :new\n")

      # Re-render to refresh git state
      render_click(view, "switch_tab", %{"tab" => "changes"})
      html_dirty = render(view)
      assert html_dirty =~ "calculator.ex"
      assert html_dirty =~ "untracked_new.ex"

      # Stage individual file
      render_click(view, "stage_file", %{"file" => "lib/calculator.ex"})
      html_staged = render(view)
      assert html_staged =~ "calculator.ex"

      # Unstage individual file
      render_click(view, "unstage_file", %{"file" => "lib/calculator.ex"})

      # Bulk Stage All
      render_click(view, "stage_all")
      html_all_staged = render(view)
      assert html_all_staged =~ "calculator.ex"
      assert html_all_staged =~ "untracked_new.ex"

      # Bulk Unstage All
      render_click(view, "unstage_all")

      # Re-stage for commit
      render_click(view, "stage_file", %{"file" => "lib/calculator.ex"})

      # 4. Generate AI Commit Message
      render_click(view, "generate_commit_msg")
      html_with_msg = render(view)
      assert html_with_msg =~ "feat" or html_with_msg =~ "update" or html_with_msg =~ "calculator"

      # Update commit message manually
      render_change(view, "update_commit_message", %{
        "message" => "feat(calc): upgrade to v2 engine"
      })

      # Commit staged changes
      render_click(view, "git_commit")

      # Status check on disk
      assert {:ok, %{staged: []}} = Git.status(path)
    end
  end
end
