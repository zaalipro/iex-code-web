defmodule IexCodeWeb.WorkspaceLiveEditorDiffsTest do
  use IexCode.E2E.Case, async: false
  @moduletag mock_llm: true
  @moduletag timeout: 120_000

  alias IexCode.Tools.Git
  alias IexCode.Tools.Git.DiffParser
  alias IexCodeWeb.WorkspaceComponents

  # ============================================================================
  # 1. File Explorer Navigation, Filtering, Selection & Security Bounds
  # ============================================================================

  describe "File Explorer & Content Preview" do
    test "renders file tree, lists project files, and filters dynamically", %{
      conn: conn,
      workspace_path: path
    } do
      workspace_write_file(
        path,
        "lib/iex_code/auth/user.ex",
        "defmodule User do\n  def schema, do: :ok\nend"
      )

      workspace_write_file(
        path,
        "lib/iex_code/auth/token.ex",
        "defmodule Token do\n  def gen, do: :ok\nend"
      )

      workspace_write_file(path, "assets/css/app.css", "body { background: #0a0d12; }")
      workspace_write_file(path, "assets/js/app.js", "console.log('init');")
      workspace_write_file(path, "config/config.exs", "import Config")

      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Switch to files tab
      render_click(view, "switch_tab", %{"tab" => "files"})

      html = render(view)
      assert html =~ "lib/iex_code/auth/user.ex"
      assert html =~ "lib/iex_code/auth/token.ex"
      assert html =~ "assets/css/app.css"
      assert html =~ "assets/js/app.js"
      assert html =~ "Select a workspace file on the left to preview contents"

      # Filter for 'token'
      render_change(view, "filter_files", %{"filter" => "token"})
      html_filtered = render(view)
      assert html_filtered =~ "token.ex"
      refute html_filtered =~ "user.ex"
      refute html_filtered =~ "app.css"

      # Search files with query
      render_change(view, "search_files", %{"query" => "app.css"})
      html_searched = render(view)
      assert html_searched =~ "app.css"
      refute html_searched =~ "token.ex"

      # Clear filter
      render_change(view, "filter_files", %{"filter" => ""})
      html_cleared = render(view)
      assert html_cleared =~ "user.ex"
      assert html_cleared =~ "token.ex"
    end

    test "selects a file from the canonical Files workbench and renders content preview", %{
      conn: conn,
      workspace_path: path
    } do
      file_content = """
      defmodule IexCode.Engine.SampleWorker do
        @moduledoc "Test sample worker"
        def perform_work(arg) do
          {:ok, arg * 2}
        end
      end
      """

      workspace_write_file(path, "lib/sample_worker.ex", file_content)

      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      render_click(view, "switch_tab", %{"tab" => "files"})

      html = render_click(view, "select_file", %{"path" => "lib/sample_worker.ex"})
      assert html =~ "lib/sample_worker.ex"
      assert html =~ "defmodule IexCode.Engine.SampleWorker do"
      assert html =~ "def perform_work(arg) do"
      assert html =~ "Copy"

      # Verify copy file button data-code attribute
      assert has_element?(
               view,
               "#copy-file-btn[data-code*='defmodule IexCode.Engine.SampleWorker']"
             )
    end

    test "refreshes file tree when new files are created on disk", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      render_click(view, "switch_tab", %{"tab" => "files"})
      refute render(view) =~ "new_module.ex"

      # Write new file to workspace disk
      workspace_write_file(path, "lib/new_module.ex", "defmodule NewModule do end")

      # Click refresh files
      render_click(view, "refresh_files")
      assert render(view) =~ "new_module.ex"
    end

    test "enforces directory jail and rejects directory traversal attempts with flash error", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Traversal via parent directories
      html1 = render_click(view, "select_file", %{"path" => "../../../etc/passwd"})
      assert html1 =~ "Invalid file path"

      # Absolute path outside sandbox root
      html2 = render_click(view, "select_file", %{"path" => "/etc/hosts"})
      assert html2 =~ "Invalid file path"

      # Root directory traversal
      html3 = render_click(view, "select_file", %{"path" => "../../.ssh/id_rsa"})
      assert html3 =~ "Invalid file path"
    end

    test "gracefully handles missing or unreadable files without crashing", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      render_click(view, "switch_tab", %{"tab" => "files"})

      # Select non-existent file inside project
      html = render_click(view, "select_file", %{"path" => "lib/does_not_exist.ex"})
      assert html =~ "Could not read file: :enoent"
      assert has_element?(view, "#workspace-shell[data-active-view='files']")
    end
  end

  # ============================================================================
  # 2. Inline Editing, Dirty Buffer State & Disk Writes
  # ============================================================================

  describe "Inline Editing & Dirty State Management" do
    test "modifies buffer, marks file dirty, reverts changes, and saves to disk", %{
      conn: conn,
      workspace_path: path
    } do
      initial_content = "defmodule EditDemo do\n  def original, do: 1\nend\n"
      workspace_write_file(path, "lib/edit_demo.ex", initial_content)

      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      render_click(view, "switch_tab", %{"tab" => "files"})

      # 1. Select file
      render_click(view, "select_file", %{"path" => "lib/edit_demo.ex"})
      assert render(view) =~ "def original, do: 1"
      refute render(view) =~ "Unsaved Changes"

      # 2. Edit content in buffer
      modified_content = "defmodule EditDemo do\n  def modified, do: 2\nend\n"
      render_change(view, "file_content_changed", %{"content" => modified_content})
      html = render(view)
      assert html =~ "Unsaved Changes"
      assert html =~ "Revert"
      assert html =~ "Save"

      # 3. Revert buffer back to disk state
      render_click(view, "revert_file_buffer")
      html_reverted = render(view)
      refute html_reverted =~ "Unsaved Changes"
      assert html_reverted =~ "def original, do: 1"

      # 4. Modify buffer again and save to disk
      render_change(view, "file_content_changed", %{"content" => modified_content})
      html_saved = render_click(view, "save_file", %{"content" => modified_content})
      assert html_saved =~ "Saved lib/edit_demo.ex"
      refute render(view) =~ "Unsaved Changes"

      # Verify disk file actually contains saved text
      full_disk_path = Path.join(path, "lib/edit_demo.ex")
      assert File.read!(full_disk_path) == modified_content
    end

    test "closes open file buffer and clears editor pane", %{
      conn: conn,
      workspace_path: path
    } do
      workspace_write_file(path, "lib/close_me.ex", "defmodule CloseMe do end")
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      render_click(view, "switch_tab", %{"tab" => "files"})

      render_click(view, "select_file", %{"path" => "lib/close_me.ex"})
      assert render(view) =~ "lib/close_me.ex"

      render_click(view, "close_file_buffer", %{"path" => "lib/close_me.ex"})
      assert render(view) =~ "Select a workspace file on the left to preview contents"
    end
  end

  # ============================================================================
  # 3. Interactive Diff Modes & Hunk Operations
  # ============================================================================

  describe "Interactive Diff Modes & Changes View" do
    test "renders one shared Change Ledger chassis, bounded signal, and shared dock", %{
      conn: conn,
      workspace_path: path
    } do
      init_git_repo!(path)
      workspace_write_file(path, "README.md", "# Change ledger\n")
      {_, 0} = System.cmd("git", ["add", "."], cd: path)
      {_, 0} = System.cmd("git", ["commit", "-m", "Initial"], cd: path)

      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      render_click(view, "switch_tab", %{"tab" => "changes"})
      render_click(view, "toggle_branch_menu")
      document = view |> render() |> LazyHTML.from_fragment()

      for selector <- [
            "#instrument-workbench-changes[data-workbench-surface='changes']",
            "#instrument-workbench-changes-title",
            "#instrument-workbench-changes-status[role='status'][aria-live='polite']",
            "#return-to-instrument-deck-changes[href='/sessions/#{session.id}'][data-phx-link='patch'][data-phx-link-state='replace'][data-return-instrument-id='instrument-card-changes']",
            "#changes-toolbar",
            "#changes-layout",
            "#changes-staging-panel",
            "#changes-diff-panel",
            "#diff-viewer-container",
            "#copy-diff-btn[phx-hook='CodeCopy'][data-code]",
            "#changes-fetch-action[phx-click='git_fetch']",
            "#changes-pull-action[phx-click='git_pull']",
            "#git-branch-form",
            "#commit-composer-form",
            "#prompt-composer",
            "#prompt-form"
          ] do
        assert node_count(document, selector) == 1, selector
      end

      assert has_element?(view, "#changes-signal-panel", "No test operation recorded")
      assert has_element?(view, "#diff-mode-inline[aria-pressed='true']")
      assert has_element?(view, "#diff-mode-split[aria-pressed='false']")
    end

    test "root Change Ledger return remains the canonical root deck", %{
      conn: conn,
      workspace_path: path
    } do
      init_git_repo!(path)
      project = create_project_fixture(%{root_path: path})
      _session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "switch_tab", %{"tab" => "changes"})

      assert has_element?(
               view,
               "#return-to-instrument-deck-changes[href='/'][data-phx-link-state='replace']"
             )
    end

    test "switches diff mode between inline and side-by-side (split)", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Navigate to changes tab
      render_click(view, "switch_tab", %{"tab" => "changes"})

      assert has_element?(view, "#diff-mode-inline[aria-pressed='true']")

      # Switch to split mode
      render_click(view, "set_diff_mode", %{"mode" => "split"})
      assert has_element?(view, "#diff-mode-split[aria-pressed='true']")
      assert has_element?(view, "#diff-mode-inline[aria-pressed='false']")

      # Switch back to inline mode
      render_click(view, "set_diff_mode", %{"mode" => "inline"})
      assert has_element?(view, "#diff-mode-inline[aria-pressed='true']")
    end

    test "switches Changes subtabs: Changes, All files, and Desktop", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      render_click(view, "switch_tab", %{"tab" => "changes"})

      # Switch to 'all' subtab
      render_click(view, "switch_changes_subtab", %{"tab" => "all"})
      assert has_element?(view, "[phx-value-tab='all'][aria-pressed='true']")

      # Switch to 'desktop' subtab
      render_click(view, "switch_changes_subtab", %{"tab" => "desktop"})
      assert has_element?(view, "[phx-value-tab='desktop'][aria-pressed='true']")

      # Switch back to 'changes' subtab
      render_click(view, "switch_changes_subtab", %{"tab" => "changes"})
      assert has_element?(view, "[phx-value-tab='changes'][aria-pressed='true']")
    end

    test "handles interactive hunk accept and reject operations", %{
      conn: conn,
      workspace_path: path
    } do
      workspace_write_file(
        path,
        "lib/demo_hunk.ex",
        "defmodule DemoHunk do\n  def val, do: 1\nend\n"
      )

      init_git_repo!(path)
      {_, 0} = System.cmd("git", ["add", "."], cd: path)
      {_, 0} = System.cmd("git", ["commit", "-m", "Initial"], cd: path)

      # Modify file
      workspace_write_file(
        path,
        "lib/demo_hunk.ex",
        "defmodule DemoHunk do\n  def val, do: 99\nend\n"
      )

      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      render_click(view, "switch_tab", %{"tab" => "changes"})

      # Select diff file
      render_click(view, "select_diff_file", %{"file" => "lib/demo_hunk.ex"})

      view
      |> element("#reject-hunk-trigger-hunk-1")
      |> render_click()

      assert has_element?(
               view,
               "#git-hunk-discard-confirmation-hunk-1[data-sheet-close-event='cancel_git_confirmation'][data-sheet-background-id='workspace-shell']"
             )

      assert has_element?(
               view,
               "#confirm-git-confirmation[phx-click*='set_attr'][phx-click*='changes-diff-panel'][phx-click*='reject_hunk']"
             )

      render_click(view, "revert_hunk", %{})
      refute has_element?(view, "#git-hunk-discard-confirmation-hunk-1")
      assert File.read!(Path.join(path, "lib/demo_hunk.ex")) =~ "def val, do: 99"

      render_click(view, "request_discard_git_hunk", %{
        "file" => "lib/demo_hunk.ex",
        "hunk_id" => "hunk-stale"
      })

      refute has_element?(view, "#git-hunk-discard-confirmation-hunk-stale")

      render_click(view, "request_discard_git_hunk", %{
        "file" => "lib/demo_hunk.ex",
        "hunk_id" => "hunk-1"
      })

      render_click(view, "reject_hunk", %{})
      refute has_element?(view, "#git-hunk-discard-confirmation-hunk-1")
      assert File.read!(Path.join(path, "lib/demo_hunk.ex")) =~ "def val, do: 1"
    end

    test "accepts all hunks and reverts only the selected staged layer", %{
      conn: conn,
      workspace_path: path
    } do
      workspace_write_file(
        path,
        "lib/all_hunks.ex",
        "defmodule AllHunks do\n  def x, do: 1\nend\n"
      )

      init_git_repo!(path)
      {_, 0} = System.cmd("git", ["add", "."], cd: path)
      {_, 0} = System.cmd("git", ["commit", "-m", "Init"], cd: path)

      workspace_write_file(
        path,
        "lib/all_hunks.ex",
        "defmodule AllHunks do\n  def x, do: 42\nend\n"
      )

      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      render_click(view, "switch_tab", %{"tab" => "changes"})

      # Accept all hunks (stage)
      render_click(view, "accept_all_hunks", %{"file" => "lib/all_hunks.ex"})
      assert has_element?(view, "[phx-value-file='lib/all_hunks.ex'][phx-value-scope='staged']")

      render_click(view, "switch_tab", %{"tab" => "changes"})

      view
      |> element("[id^='git-file-revert-trigger-']")
      |> render_click()

      assert has_element?(view, "#git-file-revert-confirmation")
      render_click(view, "revert_file", %{})
      assert {:ok, status} = Git.status(path)
      assert status.staged == []
      assert Enum.map(status.unstaged, & &1.path) == ["lib/all_hunks.ex"]
    end

    test "file revert confirmation cancels safely and confirms from server-owned state", %{
      conn: conn,
      workspace_path: path
    } do
      original = "defmodule ConfirmedRevert, do: :original\n"
      changed = "defmodule ConfirmedRevert, do: :changed\n"
      workspace_write_file(path, "lib/confirmed_revert.ex", original)
      init_git_repo!(path)
      {_, 0} = System.cmd("git", ["add", "."], cd: path)
      {_, 0} = System.cmd("git", ["commit", "-m", "Initial"], cd: path)
      workspace_write_file(path, "lib/confirmed_revert.ex", changed)

      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
      render_click(view, "switch_tab", %{"tab" => "changes"})

      render_click(view, "request_revert_git_file", %{
        "file" => "lib/confirmed_revert.ex",
        "source" => "viewer",
        "scope" => "unstaged"
      })

      assert has_element?(
               view,
               "#git-file-revert-confirmation[data-sheet-return-id='git-file-revert-trigger'][data-sheet-background-id='workspace-shell']"
             )

      assert has_element?(view, "#git-file-revert-confirmation-dialog.sf-sheet-scroll")

      assert has_element?(
               view,
               "#confirm-git-confirmation[phx-click*='set_attr'][phx-click*='changes-staging-title'][phx-click*='revert_file']"
             )

      render_click(view, "cancel_git_confirmation")
      refute has_element?(view, "#git-file-revert-confirmation")
      assert File.read!(Path.join(path, "lib/confirmed_revert.ex")) == changed

      render_click(view, "request_revert_git_file", %{
        "file" => "lib/confirmed_revert.ex",
        "source" => "viewer",
        "scope" => "unstaged"
      })

      render_click(view, "revert_file", %{})
      assert File.read!(Path.join(path, "lib/confirmed_revert.ex")) == original

      workspace_write_file(path, "lib/confirmed_revert.ex", changed)
      render_click(view, "revert_file", %{})
      assert File.read!(Path.join(path, "lib/confirmed_revert.ex")) == changed
    end

    test "partially staged files receive scope-specific unique revert trigger IDs", %{
      conn: conn,
      workspace_path: path
    } do
      workspace_write_file(path, "lib/partial.ex", "one\ntwo\n")
      init_git_repo!(path)
      {_, 0} = System.cmd("git", ["add", "."], cd: path)
      {_, 0} = System.cmd("git", ["commit", "-m", "Initial"], cd: path)
      workspace_write_file(path, "lib/partial.ex", "one staged\ntwo\n")
      {_, 0} = System.cmd("git", ["add", "--", "lib/partial.ex"], cd: path)
      workspace_write_file(path, "lib/partial.ex", "one staged\ntwo unstaged\n")

      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
      render_click(view, "switch_tab", %{"tab" => "changes"})

      trigger_ids =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("[id^='git-file-revert-trigger-']")
        |> LazyHTML.attribute("id")

      assert length(trigger_ids) == 2
      assert trigger_ids |> Enum.uniq() |> length() == 2

      for scope <- ["staged", "unstaged"] do
        selector = "[id^='git-file-revert-trigger-'][phx-value-scope='#{scope}']"

        trigger_id =
          view
          |> element(selector)
          |> render()
          |> LazyHTML.from_fragment()
          |> LazyHTML.query("button")
          |> LazyHTML.attribute("id")

        view |> element(selector) |> render_click()

        assert has_element?(
                 view,
                 "#git-file-revert-confirmation[data-sheet-return-id='#{trigger_id}']"
               )

        render_click(view, "cancel_git_confirmation")
      end
    end

    test "an authorized untracked-file confirmation can cancel or remove only that file", %{
      conn: conn,
      workspace_path: path
    } do
      init_git_repo!(path)
      workspace_write_file(path, "README.md", "# baseline\n")
      {_, 0} = System.cmd("git", ["add", "."], cd: path)
      {_, 0} = System.cmd("git", ["commit", "-m", "Initial"], cd: path)
      workspace_write_file(path, "remove_me.ex", "temporary\n")

      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
      render_click(view, "switch_tab", %{"tab" => "changes"})

      trigger =
        "[phx-click='request_revert_git_file'][phx-value-file='remove_me.ex'][phx-value-scope='untracked']"

      view |> element(trigger) |> render_click()
      render_click(view, "cancel_git_confirmation")
      assert File.exists?(Path.join(path, "remove_me.ex"))

      view |> element(trigger) |> render_click()
      render_click(view, "revert_file", %{})
      refute File.exists?(Path.join(path, "remove_me.ex"))
      assert File.exists?(Path.join(path, "README.md"))
    end

    test "stale file confirmation does not discard edits written after opening", %{
      conn: conn,
      workspace_path: path
    } do
      original = "one\n"
      opened = "two\n"
      newer = "three\n"
      workspace_write_file(path, "stale_file.ex", original)
      init_git_repo!(path)
      {_, 0} = System.cmd("git", ["add", "."], cd: path)
      {_, 0} = System.cmd("git", ["commit", "-m", "Initial"], cd: path)
      workspace_write_file(path, "stale_file.ex", opened)

      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
      render_click(view, "switch_tab", %{"tab" => "changes"})

      render_click(view, "request_revert_git_file", %{
        "file" => "stale_file.ex",
        "source" => "ledger",
        "scope" => "unstaged"
      })

      workspace_write_file(path, "stale_file.ex", newer)
      render_click(view, "revert_file", %{})

      assert File.read!(Path.join(path, "stale_file.ex")) == newer
      assert {:ok, status} = Git.status(path)
      assert status.staged == []
      assert has_element?(view, "#git-file-revert-confirmation") == false
    end

    test "scope-specific file confirmation preserves the untouched layer", %{
      conn: conn,
      workspace_path: path
    } do
      workspace_write_file(path, "partial_scope.ex", "head\n")
      init_git_repo!(path)
      {_, 0} = System.cmd("git", ["add", "."], cd: path)
      {_, 0} = System.cmd("git", ["commit", "-m", "Initial"], cd: path)
      workspace_write_file(path, "partial_scope.ex", "staged\n")
      {_, 0} = System.cmd("git", ["add", "--", "partial_scope.ex"], cd: path)
      workspace_write_file(path, "partial_scope.ex", "unstaged\n")

      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
      render_click(view, "switch_tab", %{"tab" => "changes"})

      render_click(view, "request_revert_git_file", %{
        "file" => "partial_scope.ex",
        "source" => "ledger",
        "scope" => "unstaged"
      })

      render_click(view, "revert_file", %{})

      assert File.read!(Path.join(path, "partial_scope.ex")) == "staged\n"
      assert {:ok, status} = Git.status(path)
      assert "partial_scope.ex" in Enum.map(status.staged, & &1.path)
    end

    test "staged file confirmation preserves newer worktree bytes", %{
      conn: conn,
      workspace_path: path
    } do
      workspace_write_file(path, "staged_scope.ex", "head\n")
      init_git_repo!(path)
      {_, 0} = System.cmd("git", ["add", "."], cd: path)
      {_, 0} = System.cmd("git", ["commit", "-m", "Initial"], cd: path)
      workspace_write_file(path, "staged_scope.ex", "staged\n")
      {_, 0} = System.cmd("git", ["add", "--", "staged_scope.ex"], cd: path)
      workspace_write_file(path, "staged_scope.ex", "worktree\n")

      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
      render_click(view, "switch_tab", %{"tab" => "changes"})

      render_click(view, "request_revert_git_file", %{
        "file" => "staged_scope.ex",
        "source" => "ledger",
        "scope" => "staged"
      })

      render_click(view, "revert_file", %{})

      assert File.read!(Path.join(path, "staged_scope.ex")) == "worktree\n"
      assert {:ok, status} = Git.status(path)
      assert status.staged == []
      assert "staged_scope.ex" in Enum.map(status.unstaged, & &1.path)
    end

    test "viewer Revert File restores both layers for a partially staged file", %{
      conn: conn,
      workspace_path: path
    } do
      workspace_write_file(path, "viewer_all.ex", "head\n")
      init_git_repo!(path)
      {_, 0} = System.cmd("git", ["add", "."], cd: path)
      {_, 0} = System.cmd("git", ["commit", "-m", "Initial"], cd: path)
      workspace_write_file(path, "viewer_all.ex", "staged\n")
      {_, 0} = System.cmd("git", ["add", "--", "viewer_all.ex"], cd: path)
      workspace_write_file(path, "viewer_all.ex", "worktree\n")
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}?view=changes")
      render_click(view, "select_diff_file", %{"file" => "viewer_all.ex", "scope" => "unstaged"})
      view |> element("#git-file-revert-trigger") |> render_click()
      assert has_element?(view, "#git-file-revert-confirmation", "Revert entire file?")
      render_click(view, "revert_file", %{})

      assert File.read!(Path.join(path, "viewer_all.ex")) == "head\n"
      assert {:ok, status} = Git.status(path)
      assert status.clean?
    end

    test "same-id replacement hunk is not discarded after confirmation opens", %{
      conn: conn,
      workspace_path: path
    } do
      original = Enum.map_join(1..24, "\n", &"line #{&1}") <> "\n"
      opened = String.replace(original, "line 2\n", "opened hunk\n")
      replacement = String.replace(original, "line 2\n", "swappp hunk\n")
      workspace_write_file(path, "hunk_race.ex", original)
      init_git_repo!(path)
      {_, 0} = System.cmd("git", ["add", "."], cd: path)
      {_, 0} = System.cmd("git", ["commit", "-m", "Initial"], cd: path)
      workspace_write_file(path, "hunk_race.ex", opened)

      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
      render_click(view, "switch_tab", %{"tab" => "changes"})

      render_click(view, "request_discard_git_hunk", %{
        "file" => "hunk_race.ex",
        "hunk_id" => "hunk-1"
      })

      assert has_element?(view, "#git-hunk-discard-confirmation-hunk-1")

      workspace_write_file(path, "hunk_race.ex", replacement)
      render_click(view, "reject_hunk", %{})

      assert File.read!(Path.join(path, "hunk_race.ex")) == replacement
      assert {:ok, status} = Git.status(path)
      assert status.staged == []
      refute has_element?(view, "#git-hunk-discard-confirmation-hunk-1")
    end

    test "symlink substitution cannot redirect an untracked-file confirmation", %{
      conn: conn,
      workspace_path: path
    } do
      workspace_write_file(path, "target.ex", "head target\n")
      init_git_repo!(path)
      {_, 0} = System.cmd("git", ["add", "."], cd: path)
      {_, 0} = System.cmd("git", ["commit", "-m", "Initial"], cd: path)
      workspace_write_file(path, "target.ex", "dirty target\n")
      workspace_write_file(path, "victim.ex", "temporary\n")

      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
      render_click(view, "switch_tab", %{"tab" => "changes"})

      render_click(view, "request_revert_git_file", %{
        "file" => "victim.ex",
        "source" => "ledger",
        "scope" => "untracked"
      })

      File.rm!(Path.join(path, "victim.ex"))
      File.ln_s!("target.ex", Path.join(path, "victim.ex"))
      render_click(view, "revert_file", %{})

      assert File.read!(Path.join(path, "target.ex")) == "dirty target\n"
      assert {:ok, status} = Git.status(path)
      assert status.staged == []
      assert {:ok, "target.ex"} = File.read_link(Path.join(path, "victim.ex"))
    end

    test "accept all rejects a selected diff changed after it was rendered", %{
      conn: conn,
      workspace_path: path
    } do
      workspace_write_file(path, "stale_all.ex", "head\n")
      init_git_repo!(path)
      {_, 0} = System.cmd("git", ["add", "."], cd: path)
      {_, 0} = System.cmd("git", ["commit", "-m", "Initial"], cd: path)
      workspace_write_file(path, "stale_all.ex", "rendered\n")

      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
      render_click(view, "switch_tab", %{"tab" => "changes"})

      workspace_write_file(path, "stale_all.ex", "replacement\n")
      render_click(view, "accept_all_hunks", %{"file" => "stale_all.ex"})

      assert {:ok, status} = Git.status(path)
      assert status.staged == []
      assert File.read!(Path.join(path, "stale_all.ex")) == "replacement\n"
    end

    test "oversized file confirmation fails closed without changing index or disk", %{
      conn: conn,
      workspace_path: path
    } do
      original = String.duplicate("a", 2 * 1_024 * 1_024 + 1)
      changed = String.duplicate("b", byte_size(original))
      workspace_write_file(path, "oversized.ex", original)
      init_git_repo!(path)
      {_, 0} = System.cmd("git", ["add", "."], cd: path)
      {_, 0} = System.cmd("git", ["commit", "-m", "Initial"], cd: path)
      workspace_write_file(path, "oversized.ex", changed)
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}?view=changes")

      render_click(view, "request_revert_git_file", %{
        "file" => "oversized.ex",
        "source" => "ledger",
        "scope" => "unstaged"
      })

      refute has_element?(view, "#git-file-revert-confirmation")
      assert File.read!(Path.join(path, "oversized.ex")) == changed
      assert {:ok, status} = Git.status(path)
      assert status.staged == []
    end

    test "same-project session transition clears pending Git authority", %{
      conn: conn,
      workspace_path: path
    } do
      init_git_repo!(path)
      workspace_write_file(path, "README.md", "head\n")
      {_, 0} = System.cmd("git", ["add", "."], cd: path)
      {_, 0} = System.cmd("git", ["commit", "-m", "Initial"], cd: path)
      workspace_write_file(path, "pending.ex", "temporary\n")

      project = create_project_fixture(%{root_path: path})
      first = create_session_fixture(project)
      second = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{first.id}?view=changes")

      render_click(view, "request_revert_git_file", %{
        "file" => "pending.ex",
        "source" => "ledger",
        "scope" => "untracked"
      })

      assert has_element?(view, "#git-file-revert-confirmation")
      render_patch(view, ~p"/sessions/#{second.id}?view=changes")
      refute has_element?(view, "#git-file-revert-confirmation")

      render_click(view, "revert_file", %{})
      assert File.read!(Path.join(path, "pending.ex")) == "temporary\n"
    end

    test "diff selection and file confirmation reject incomplete or mismatched input", %{
      conn: conn,
      workspace_path: path
    } do
      workspace_write_file(path, "a.ex", "head a\n")
      workspace_write_file(path, "b.ex", "head b\n")
      init_git_repo!(path)
      {_, 0} = System.cmd("git", ["add", "."], cd: path)
      {_, 0} = System.cmd("git", ["commit", "-m", "Initial"], cd: path)
      workspace_write_file(path, "a.ex", "dirty a\n")
      workspace_write_file(path, "b.ex", "dirty b\n")

      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}?view=changes")
      render_click(view, "select_diff_file", %{"file" => "b.ex", "scope" => "unstaged"})
      assert has_element?(view, ".changes-file-row--selected [phx-value-file='b.ex']")

      render_click(view, "select_diff_file", %{"file" => "a.ex"})
      assert has_element?(view, ".changes-file-row--selected [phx-value-file='b.ex']")

      render_click(view, "request_revert_git_file", %{
        "file" => "a.ex",
        "source" => "viewer",
        "scope" => "unstaged"
      })

      refute has_element?(view, "#git-file-revert-confirmation")

      render_click(view, "request_revert_git_file", %{
        "file" => "b.ex",
        "source" => "forged",
        "scope" => "unstaged"
      })

      refute has_element?(view, "#git-file-revert-confirmation")

      render_click(view, "accept_all_hunks", %{"file" => "b.ex", "scope" => "forged"})
      assert {:ok, status} = Git.status(path)
      assert status.staged == []
    end

    test "direct palette source cannot bypass Changes gate", %{conn: conn, workspace_path: path} do
      init_git_repo!(path)
      workspace_write_file(path, "README.md", "head\n")
      {_, 0} = System.cmd("git", ["add", "."], cd: path)
      {_, 0} = System.cmd("git", ["commit", "-m", "Initial"], cd: path)
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      render_click(view, "git_fetch", %{"source" => "palette"})
      refute has_element?(view, "#changes-fetch-action")
      refute has_element?(view, "#flash-info", "Fetched latest remote updates")
      assert {:ok, "main"} = Git.current_branch(path)
    end

    test "same-view Changes re-entry clears a pending confirmation", %{
      conn: conn,
      workspace_path: path
    } do
      init_git_repo!(path)
      workspace_write_file(path, "README.md", "head\n")
      {_, 0} = System.cmd("git", ["add", "."], cd: path)
      {_, 0} = System.cmd("git", ["commit", "-m", "Initial"], cd: path)
      workspace_write_file(path, "pending_same_view.ex", "temporary\n")
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}?view=changes")

      render_click(view, "request_revert_git_file", %{
        "file" => "pending_same_view.ex",
        "source" => "ledger",
        "scope" => "untracked"
      })

      assert has_element?(view, "#git-file-revert-confirmation")
      render_click(view, "switch_tab", %{"tab" => "changes"})
      refute has_element?(view, "#git-file-revert-confirmation")
      render_click(view, "revert_file", %{})
      assert File.read!(Path.join(path, "pending_same_view.ex")) == "temporary\n"
    end

    test "immediate accept hunk rejects a replacement patch with the same hunk id", %{
      conn: conn,
      workspace_path: path
    } do
      original = "line one\nline two\nline three\n"
      opened = "line one\nvalue AAA\nline three\n"
      replacement = "line one\nvalue BBB\nline three\n"
      workspace_write_file(path, "accept_race.ex", original)
      init_git_repo!(path)
      {_, 0} = System.cmd("git", ["add", "."], cd: path)
      {_, 0} = System.cmd("git", ["commit", "-m", "Initial"], cd: path)
      workspace_write_file(path, "accept_race.ex", opened)
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}?view=changes")
      render_click(view, "select_diff_file", %{"file" => "accept_race.ex", "scope" => "unstaged"})
      workspace_write_file(path, "accept_race.ex", replacement)
      render_click(view, "accept_hunk", %{"file" => "accept_race.ex", "hunk_id" => "hunk-1"})

      assert File.read!(Path.join(path, "accept_race.ex")) == replacement
      assert {:ok, status} = Git.status(path)
      assert status.staged == []
    end

    test "immediate unstage hunk rejects a replacement index patch with the same hunk id", %{
      conn: conn,
      workspace_path: path
    } do
      original = "line one\nvalue 000\nline three\n"
      opened = "line one\nvalue AAA\nline three\n"
      replacement = "line one\nvalue BBB\nline three\n"
      workspace_write_file(path, "unstage_race.ex", original)
      init_git_repo!(path)
      {_, 0} = System.cmd("git", ["add", "."], cd: path)
      {_, 0} = System.cmd("git", ["commit", "-m", "Initial"], cd: path)
      workspace_write_file(path, "unstage_race.ex", opened)
      {_, 0} = System.cmd("git", ["add", "--", "unstage_race.ex"], cd: path)
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}?view=changes")
      render_click(view, "select_diff_file", %{"file" => "unstage_race.ex", "scope" => "staged"})
      workspace_write_file(path, "unstage_race.ex", replacement)
      {_, 0} = System.cmd("git", ["add", "--", "unstage_race.ex"], cd: path)
      render_click(view, "unstage_hunk", %{"file" => "unstage_race.ex", "hunk_id" => "hunk-1"})

      {index_content, 0} = System.cmd("git", ["show", ":unstage_race.ex"], cd: path)
      assert index_content == replacement
      assert File.read!(Path.join(path, "unstage_race.ex")) == replacement
    end
  end

  # ============================================================================
  # 4. DiffParser Pure Engine Verification
  # ============================================================================

  describe "DiffParser Engine & Hunk Operations" do
    test "parses complex multi-hunk unified diff into structured FileDiff and Hunk records" do
      sample_diff = """
      diff --git a/lib/app.ex b/lib/app.ex
      index 1234567..89abcdef 100644
      --- a/lib/app.ex
      +++ b/lib/app.ex
      @@ -10,6 +10,8 @@ defmodule App do
         def start do
           :ok
         end
      +  def reload do
      +    :reloaded
      +  end
       
         def stop do
      @@ -40,4 +42,6 @@ defmodule App do
         def restart do
      -    stop()
      -    start()
      +    with :ok <- stop() do
      +      start()
      +    end
         end
       end
      """

      assert {:ok, [file_diff]} = DiffParser.parse(sample_diff)
      assert file_diff.path == "lib/app.ex"
      assert file_diff.status == :modified
      assert length(file_diff.hunks) == 2
      assert file_diff.additions == 6
      assert file_diff.deletions == 2

      [hunk1, hunk2] = file_diff.hunks
      assert hunk1.old_start == 10
      assert hunk1.old_lines == 6
      assert hunk1.new_start == 10
      assert hunk1.new_lines == 8
      assert hunk1.status == :pending
      assert Enum.count(hunk1.lines, &(&1.type == :addition)) == 3

      assert hunk2.old_start == 40
      assert hunk2.old_lines == 4
      assert hunk2.new_start == 42
      assert hunk2.new_lines == 6
      assert Enum.count(hunk2.lines, &(&1.type == :deletion)) == 2
      assert Enum.count(hunk2.lines, &(&1.type == :addition)) == 3
    end

    test "formats standalone hunk patch ready for git apply" do
      sample_diff = """
      diff --git a/lib/math.ex b/lib/math.ex
      --- a/lib/math.ex
      +++ b/lib/math.ex
      @@ -5,3 +5,4 @@ defmodule Math do
         def add(a, b), do: a + b
      +  def sub(a, b), do: a - b
       end
      """

      {:ok, [file_diff]} = DiffParser.parse(sample_diff)
      [hunk] = file_diff.hunks

      patch = DiffParser.format_hunk_patch(file_diff, hunk)
      assert patch =~ "--- a/lib/math.ex"
      assert patch =~ "+++ b/lib/math.ex"
      assert patch =~ "@@ -5,3 +5,4 @@"
      assert patch =~ "+  def sub(a, b), do: a - b"
    end
  end

  # ============================================================================
  # 5. Component Rendering Verification (Inline & Split Diff Viewers)
  # ============================================================================

  describe "WorkspaceComponents Diff Rendering" do
    test "Change Ledger CSS keeps full-opacity form tokens and strict wide boundary" do
      css = File.read!("assets/css/app.css")

      assert css =~ "#instrument-workbench-changes #git-branch-name::placeholder"
      assert css =~ "#instrument-workbench-changes #commit-message::placeholder"
      assert css =~ "opacity: 1;"
      assert css =~ "@media (max-width: 63.99rem)"
      refute css =~ "#instrument-workbench-changes :where(input, textarea)::placeholder"
    end

    test "forwards staged state so a staged hunk only offers unstage" do
      diff = """
      diff --git a/lib/staged.ex b/lib/staged.ex
      --- a/lib/staged.ex
      +++ b/lib/staged.ex
      @@ -1 +1 @@
      -old
      +new
      """

      rendered =
        Phoenix.LiveViewTest.render_component(&WorkspaceComponents.interactive_diff_viewer/1, %{
          diff_text: diff,
          file_path: "lib/staged.ex",
          staged: true
        })

      document = LazyHTML.from_fragment(rendered)
      assert node_count(document, "[phx-click='unstage_hunk']") == 1
      assert node_count(document, "[phx-click='accept_hunk']") == 0
      assert node_count(document, "[phx-click='request_discard_git_hunk']") == 0
      assert node_count(document, "[phx-click='request_revert_git_hunk']") == 0
    end

    test "unstaged viewer exposes a path-aware typed Accept All action" do
      diff = """
      diff --git a/lib/path.ex b/lib/path.ex
      --- a/lib/path.ex
      +++ b/lib/path.ex
      @@ -1 +1 @@
      -old
      +new
      """

      rendered =
        Phoenix.LiveViewTest.render_component(&WorkspaceComponents.interactive_diff_viewer/1, %{
          diff_text: diff,
          file_path: "lib/path.ex",
          staged: false
        })

      document = LazyHTML.from_fragment(rendered)

      assert node_count(
               document,
               "button[type='button'][phx-click='accept_all_hunks'][aria-label='Stage all changes in lib/path.ex']"
             ) == 1
    end

    test "renders inline_diff with additions, deletions, context, and header lines" do
      diff = """
      --- a/lib/test.ex
      +++ b/lib/test.ex
      @@ -1,3 +1,3 @@
       defmodule Test do
      -  def old_val, do: 1
      +  def new_val, do: 2
       end
      """

      rendered =
        Phoenix.LiveViewTest.render_component(&WorkspaceComponents.inline_diff/1, %{diff: diff})

      assert rendered =~ "var(--sf-success-text)"
      assert rendered =~ "def new_val, do: 2"
      assert rendered =~ "var(--sf-live-text)"
      assert rendered =~ "def old_val, do: 1"
      assert rendered =~ "defmodule Test do"
      assert rendered =~ "var(--sf-code-text)"
    end

    test "renders split_diff with dual columns for original and modified" do
      diff = """
      --- a/lib/split_test.ex
      +++ b/lib/split_test.ex
      @@ -1,2 +1,2 @@
      -old line
      +new line
      """

      rendered =
        Phoenix.LiveViewTest.render_component(&WorkspaceComponents.split_diff/1, %{diff: diff})

      assert rendered =~ "Original"
      assert rendered =~ "Modified"
      assert rendered =~ "old line"
      assert rendered =~ "new line"
    end
  end

  defp node_count(document, selector) do
    document |> LazyHTML.query(selector) |> LazyHTML.to_tree() |> length()
  end
end
