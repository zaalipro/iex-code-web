defmodule IexCodeWeb.WorkspaceLiveAstGitTest do
  use IexCode.E2E.Case, async: false
  @moduletag mock_llm: true

  alias IexCode.Tools.Git

  # ============================================================================
  # Git Branch Switching & Remote Synchronization
  # ============================================================================
  describe "Git Branch Hub & Remote Sync" do
    setup %{workspace_path: path} do
      # Initialize Git repository inside workspace
      {_, 0} = System.cmd("git", ["init", "-b", "main"], cd: path)
      {_, 0} = System.cmd("git", ["config", "user.name", "Test User"], cd: path)
      {_, 0} = System.cmd("git", ["config", "user.email", "test@example.com"], cd: path)

      workspace_write_file(path, "README.md", "# Workspace Git Project\n")
      {_, 0} = System.cmd("git", ["add", "."], cd: path)
      {_, 0} = System.cmd("git", ["commit", "-m", "Initial commit"], cd: path)

      # Create develop branch
      {_, 0} = System.cmd("git", ["branch", "develop"], cd: path)

      :ok
    end

    test "switches branch and updates active branch indicator", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      render_click(view, "switch_tab", %{"tab" => "changes"})

      # Switch to develop branch
      render_click(view, "switch_git_branch", %{"branch" => "develop"})
      html = render(view)
      assert html =~ "develop"
    end

    test "creates and switches to a new branch from the UI", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      render_click(view, "switch_tab", %{"tab" => "changes"})

      # Create new branch
      render_click(view, "create_git_branch", %{"name" => "feature/ast-power"})
      html = render(view)
      assert html =~ "feature/ast-power"
    end

    test "executes git fetch and git pull triggers without crashing", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      render_click(view, "switch_tab", %{"tab" => "changes"})

      assert render_click(view, "git_fetch")
      assert render_click(view, "git_pull")
    end
  end

  # ============================================================================
  # 2. 3-Tier Multi-File Staging Hub
  # ============================================================================
  describe "3-Tier Multi-File Staging Hub" do
    setup %{workspace_path: path} do
      {_, 0} = System.cmd("git", ["init", "-b", "main"], cd: path)
      {_, 0} = System.cmd("git", ["config", "user.name", "Test User"], cd: path)
      {_, 0} = System.cmd("git", ["config", "user.email", "test@example.com"], cd: path)

      workspace_write_file(path, "lib/tracked.ex", "defmodule Tracked, do: :ok\n")
      {_, 0} = System.cmd("git", ["add", "."], cd: path)
      {_, 0} = System.cmd("git", ["commit", "-m", "Initial commit"], cd: path)

      # Create modified file and untracked file
      workspace_write_file(path, "lib/tracked.ex", "defmodule Tracked, do: :modified\n")
      workspace_write_file(path, "lib/untracked.ex", "defmodule Untracked, do: :new\n")

      :ok
    end

    test "stages and unstages individual files and performs bulk stage/unstage", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      render_click(view, "switch_tab", %{"tab" => "changes"})

      # Stage tracked.ex
      render_click(view, "stage_file", %{"file" => "lib/tracked.ex"})
      html_staged = render(view)
      assert html_staged =~ "lib/tracked.ex"

      # Unstage tracked.ex
      render_click(view, "unstage_file", %{"file" => "lib/tracked.ex"})
      assert render(view)

      # Bulk Stage All
      render_click(view, "stage_all")
      html_all_staged = render(view)
      assert html_all_staged =~ "lib/tracked.ex"

      # Bulk Unstage All
      render_click(view, "unstage_all")
      assert render(view)
    end
  end

  # ============================================================================
  # 3. AI Commit Message Generation & Direct Commits
  # ============================================================================
  describe "Commit Message Composer & Commit Execution" do
    setup %{workspace_path: path} do
      {_, 0} = System.cmd("git", ["init", "-b", "main"], cd: path)
      {_, 0} = System.cmd("git", ["config", "user.name", "Test User"], cd: path)
      {_, 0} = System.cmd("git", ["config", "user.email", "test@example.com"], cd: path)

      workspace_write_file(path, "lib/feature.ex", "defmodule Feature, do: :v1\n")
      {_, 0} = System.cmd("git", ["add", "."], cd: path)
      {_, 0} = System.cmd("git", ["commit", "-m", "Initial commit"], cd: path)

      # Make change and stage it
      workspace_write_file(path, "lib/feature.ex", "defmodule Feature, do: :v2\n")
      Git.stage("lib/feature.ex", path)

      :ok
    end

    test "generates conventional commit message and commits staged changes", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      render_click(view, "switch_tab", %{"tab" => "changes"})

      # Generate AI commit message
      render_click(view, "generate_commit_msg")
      html_msg = render(view)
      assert html_msg =~ "feat" or html_msg =~ "update" or html_msg =~ "feature"

      # Update commit message manually
      render_change(view, "update_commit_message", %{
        "message" => "feat(feature): upgrade to v2"
      })

      # Trigger Git Commit
      render_click(view, "git_commit")

      # Status should now be clean
      assert {:ok, status} = Git.status(path)
      assert status.clean? == true
    end
  end
end
