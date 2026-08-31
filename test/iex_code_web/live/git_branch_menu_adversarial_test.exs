defmodule IexCodeWeb.GitBranchMenuAdversarialTest do
  use IexCode.E2E.Case, async: false
  @moduletag mock_llm: true
  @moduletag timeout: 180_000

  alias IexCode.Tools.Git

  setup %{workspace_path: path} do
    {_, 0} = System.cmd("git", ["init", "-b", "main"], cd: path)
    {_, 0} = System.cmd("git", ["config", "user.name", "Live Tester"], cd: path)
    {_, 0} = System.cmd("git", ["config", "user.email", "livetester@iexcode.local"], cd: path)

    workspace_write_file(path, "README.md", "# Test Project\n")
    {_, 0} = System.cmd("git", ["add", "."], cd: path)
    {_, 0} = System.cmd("git", ["commit", "-m", "chore: initial commit"], cd: path)

    # Create additional branches
    {_, 0} = System.cmd("git", ["branch", "feature/payments"], cd: path)
    {_, 0} = System.cmd("git", ["branch", "fix/login-crash"], cd: path)

    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)

    {:ok, %{project: project, session: session, workspace_path: path}}
  end

  describe "Git Branch Menu Rendering in LiveView" do
    test "toggling branch menu renders all branches with b.current? without KeyError", %{
      conn: conn,
      session: session,
      workspace_path: path
    } do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Switch to changes tab
      render_click(view, "switch_tab", %{"tab" => "changes"})

      # Initially branch menu is not open
      refute has_element?(view, "#changes-branch-menu")

      # Toggle branch menu open
      render_click(view, "toggle_branch_menu")

      # Verify branch menu header and branches list are rendered
      assert has_element?(
               view,
               "#changes-branch-menu[role='region'][aria-labelledby='changes-branch-menu-title']"
             )

      assert has_element?(view, "#changes-branch-menu-title", "Branches")
      assert has_element?(view, "#changes-branch-menu button[phx-value-branch='main']", "main")

      assert has_element?(
               view,
               "#changes-branch-menu button[phx-value-branch='feature/payments']",
               "feature/payments"
             )

      assert has_element?(
               view,
               "#changes-branch-menu button[phx-value-branch='fix/login-crash']",
               "fix/login-crash"
             )

      # Verify the active branch is exposed with the current semantic label.
      assert has_element?(
               view,
               "#changes-branch-menu button[phx-value-branch='main'] [aria-label='Current branch']"
             )

      # Toggle branch menu closed
      render_click(view, "toggle_branch_menu")
      refute has_element?(view, "#changes-branch-menu")

      # Switch branch to feature/payments
      render_click(view, "switch_git_branch", %{"branch" => "feature/payments"})

      # Toggle menu open again and verify feature/payments is current
      render_click(view, "toggle_branch_menu")
      assert has_element?(view, "#changes-branch-menu-title", "Branches")

      assert has_element?(
               view,
               "#changes-branch-menu button[phx-value-branch='feature/payments'] [aria-label='Current branch']"
             )

      # Verify current branch in git matches
      assert {:ok, "feature/payments"} = Git.current_branch(path)
    end
  end
end
