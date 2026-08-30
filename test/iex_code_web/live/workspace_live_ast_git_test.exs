defmodule IexCodeWeb.WorkspaceLiveAstGitTest do
  use IexCode.E2E.Case, async: false
  @moduletag mock_llm: true

  alias IexCode.{Repo, Tools.Git}

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

    test "renders factual Change Ledger summary and newest test operation without sentinel leakage",
         %{
           conn: conn,
           workspace_path: path
         } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)

      older =
        create_operation_fixture(session, %{
          op_type: "run_tests",
          status: "failed",
          duration_ms: 7
        })

      _newer_non_test =
        create_operation_fixture(session, %{
          op_type: "tool",
          status: "completed",
          title: "NONTEST-TITLE-SENTINEL"
        })

      newest =
        create_operation_fixture(session, %{
          op_type: "run_tests",
          status: "completed",
          duration_ms: 42,
          title: "TEST-TITLE-SENTINEL",
          result: "TEST-RESULT-SENTINEL",
          error_message: "TEST-ERROR-SENTINEL",
          params: %{"secret" => "TEST-PARAM-SENTINEL"},
          pid_str: "TEST-PID-SENTINEL",
          agent_name: "TEST-AGENT-SENTINEL"
        })

      _older = retime(older, ~U[2026-08-28 10:00:00Z])
      _newest = retime(newest, ~U[2026-08-28 12:00:00Z])

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
      render_click(view, "switch_tab", %{"tab" => "changes"})

      assert has_element?(view, "#changes-signal-panel", "Latest test operation")
      assert has_element?(view, "#changes-signal-panel", "completed · 42 ms")

      document = view |> render() |> LazyHTML.from_fragment()
      signal = document |> LazyHTML.query("#changes-signal-panel") |> LazyHTML.text()

      for secret <- [
            "NONTEST-TITLE-SENTINEL",
            "TEST-TITLE-SENTINEL",
            "TEST-RESULT-SENTINEL",
            "TEST-ERROR-SENTINEL",
            "TEST-PARAM-SENTINEL",
            "TEST-PID-SENTINEL",
            "TEST-AGENT-SENTINEL"
          ] do
        refute signal =~ secret
      end

      without_duration =
        create_operation_fixture(session, %{
          op_type: "run_tests",
          status: "failed",
          duration_ms: nil
        })
        |> retime(~U[2026-08-28 13:00:00Z])

      send(view.pid, {:operation_created, without_duration})
      _ = :sys.get_state(view.pid)

      updated_signal =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#changes-signal-panel")
        |> LazyHTML.text()

      assert updated_signal =~ "Latest test operation"
      assert updated_signal =~ "failed"
      refute updated_signal =~ "ms"
    end

    test "same-view Changes re-entry synchronously accepts new tracked and untracked facts", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
      render_click(view, "switch_tab", %{"tab" => "changes"})

      workspace_write_file(path, "README.md", "# externally changed\n")
      workspace_write_file(path, "lib/untracked_same_view.ex", "defmodule SameView, do: :new\n")

      render_click(view, "switch_tab", %{"tab" => "changes"})

      assert has_element?(view, "[phx-click='select_diff_file'][phx-value-file='README.md']")

      assert has_element?(
               view,
               "[phx-click='stage_file'][phx-value-file='lib/untracked_same_view.ex']"
             )
    end

    test "renders the 500-path retained bound without claiming a clean repository", %{
      conn: conn,
      workspace_path: path
    } do
      for index <- 1..501 do
        workspace_write_file(path, "bounded/status_#{index}.ex", "#{index}\n")
      end

      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
      render_click(view, "switch_tab", %{"tab" => "changes"})

      assert has_element?(view, "#git-status-truncated", "Showing bounded Git status")

      assert has_element?(
               view,
               "#changes-signal-panel[data-summary-status='attention']",
               "Showing bounded Git status"
             )

      refute has_element?(view, "#changes-signal-panel", "No changes")
      refute has_element?(view, "#changes-signal-panel", "all clean")

      render_click(view, "stage_all", %{})
      assert {:ok, status} = Git.status(path)
      assert status.staged == []
    end

    test "rejects forged branches, foreign paths, and Git pathspec magic", %{
      conn: conn,
      workspace_path: path
    } do
      workspace_write_file(path, "safe.ex", "safe\n")
      workspace_write_file(path, "*.ex", "literal pathspec name\n")
      workspace_write_file(path, ":!safe.ex", "short-form pathspec name\n")
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
      render_click(view, "switch_tab", %{"tab" => "changes"})

      render_click(view, "switch_git_branch", %{"branch" => "forged-branch"})
      render_click(view, "stage_file", %{"file" => "../outside.ex"})
      render_click(view, "stage_file", %{"file" => "*.ex"})
      render_click(view, "stage_file", %{"file" => ":!safe.ex"})
      render_click(view, "select_diff_file", %{"file" => "../outside.ex", "scope" => "unstaged"})
      render_click(view, "set_diff_mode", %{"mode" => "forged"})
      render_click(view, "switch_changes_subtab", %{"tab" => "forged"})

      assert {:ok, "main"} = Git.current_branch(path)
      assert {:ok, status} = Git.status(path)
      assert "safe.ex" in status.untracked
      assert "*.ex" in status.untracked
      assert ":!safe.ex" in status.untracked
    end

    test "rejects option-looking branches without touching dirty worktree", %{
      conn: conn,
      workspace_path: path
    } do
      workspace_write_file(path, "dirty.ex", "clean\n")
      {_, 0} = System.cmd("git", ["add", "."], cd: path)
      {_, 0} = System.cmd("git", ["commit", "-m", "Baseline"], cd: path)
      {_, 0} = System.cmd("git", ["update-ref", "refs/heads/-f", "HEAD"], cd: path)
      workspace_write_file(path, "dirty.ex", "do not discard\n")

      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
      render_click(view, "switch_tab", %{"tab" => "changes"})
      render_click(view, "create_git_branch", %{"name" => "--detach"})
      render_click(view, "switch_git_branch", %{"branch" => "-f"})

      assert {:ok, "main"} = Git.current_branch(path)
      assert File.read!(Path.join(path, "dirty.ex")) == "do not discard\n"
      assert {:ok, branches} = Git.branches(path)
      refute Enum.any?(branches, &(&1.name == "--detach"))
    end

    test "re-lists branches under lock before switching a stale cached name", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
      render_click(view, "switch_tab", %{"tab" => "changes"})

      {_, 0} = System.cmd("git", ["branch", "-D", "develop"], cd: path)
      {_, 0} = System.cmd("git", ["tag", "develop"], cd: path)
      render_click(view, "switch_git_branch", %{"branch" => "develop"})

      assert {:ok, "main"} = Git.current_branch(path)
    end

    test "a synchronous Git error clears the prior accepted detailed snapshot", %{
      conn: conn,
      workspace_path: path
    } do
      workspace_write_file(path, "README.md", "# accepted before error\n")
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
      render_click(view, "switch_tab", %{"tab" => "changes"})
      assert has_element?(view, "[phx-value-file='README.md'][phx-value-scope='unstaged']")

      File.rename!(Path.join(path, ".git"), Path.join(path, ".git-offline"))
      render_click(view, "refresh_git_state", %{})

      assert has_element?(view, "#changes-signal-panel", "Git unavailable")
      refute has_element?(view, "[phx-value-file='README.md']")
      refute has_element?(view, "#git-file-revert-trigger")
      assert has_element?(view, "#diff-viewer-container", "No patch or diff selected")
    end

    test "renders conflicts as bounded facts with visible conflict text", %{
      conn: conn,
      workspace_path: path
    } do
      {_, 0} = System.cmd("git", ["switch", "develop"], cd: path)
      workspace_write_file(path, "README.md", "develop side\n")
      {_, 0} = System.cmd("git", ["add", "--", "README.md"], cd: path)
      {_, 0} = System.cmd("git", ["commit", "-m", "Develop side"], cd: path)
      {_, 0} = System.cmd("git", ["switch", "main"], cd: path)
      workspace_write_file(path, "README.md", "main side\n")
      {_, 0} = System.cmd("git", ["add", "--", "README.md"], cd: path)
      {_, 0} = System.cmd("git", ["commit", "-m", "Main side"], cd: path)
      {_, 1} = System.cmd("git", ["merge", "develop"], cd: path, stderr_to_stdout: true)

      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
      render_click(view, "switch_tab", %{"tab" => "changes"})

      assert has_element?(
               view,
               "#changes-signal-panel[data-summary-status='attention']",
               "Conflicts"
             )

      assert has_element?(view, "#changes-signal-panel", "1")
      assert has_element?(view, "#changes-staging-panel", "Conflict")
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

    test "bulk stage and unstage ignore forged payloads", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
      render_click(view, "switch_tab", %{"tab" => "changes"})

      render_click(view, "stage_all", %{"file" => "forged.ex"})
      render_click(view, "unstage_all", %{"file" => "forged.ex"})

      assert {:ok, status} = Git.status(path)
      assert status.staged == []
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

  defp retime(struct, inserted_at) do
    struct
    |> Ecto.Changeset.change(inserted_at: inserted_at, updated_at: inserted_at)
    |> Repo.update!()
  end
end
