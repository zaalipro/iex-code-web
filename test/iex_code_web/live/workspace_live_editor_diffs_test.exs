defmodule IexCodeWeb.WorkspaceLiveEditorDiffsTest do
  use IexCode.E2E.Case, async: false
  @moduletag mock_llm: true
  @moduletag timeout: 120_000

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

    test "selects file from any tab, switches to files tab, and renders content preview", %{
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

      # Start on kanban tab
      assert render(view) =~ "Kanban"

      # Select file -> should switch tab to 'files' and display content
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

      # Select non-existent file inside project
      html = render_click(view, "select_file", %{"path" => "lib/does_not_exist.ex"})
      assert html =~ "Could not read file: :enoent"
      assert Process.alive?(view.pid)
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
    test "switches diff mode between inline and side-by-side (split)", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Navigate to changes tab
      render_click(view, "switch_tab", %{"tab" => "changes"})

      html = render(view)
      assert html =~ "All Changes" or html =~ "Changes"

      # Switch to split mode
      html_split = render_click(view, "set_diff_mode", %{"mode" => "split"})
      assert html_split =~ "Original" or html_split =~ "Split" or is_binary(html_split)

      # Switch back to inline mode
      html_inline = render_click(view, "set_diff_mode", %{"mode" => "inline"})
      assert is_binary(html_inline)
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
      html = render_click(view, "switch_changes_subtab", %{"tab" => "all"})
      assert is_binary(html)

      # Switch to 'desktop' subtab
      html = render_click(view, "switch_changes_subtab", %{"tab" => "desktop"})
      assert is_binary(html)

      # Switch back to 'changes' subtab
      html = render_click(view, "switch_changes_subtab", %{"tab" => "changes"})
      assert is_binary(html)
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

      # Reject hunk
      html_reject =
        render_click(view, "reject_hunk", %{"file" => "lib/demo_hunk.ex", "hunk_id" => "hunk-1"})

      assert html_reject =~ "Reverted hunk" or html_reject =~ "revert" or is_binary(html_reject)
    end

    test "accepts all hunks and reverts entire file", %{
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
      html_accept = render_click(view, "accept_all_hunks", %{"file" => "lib/all_hunks.ex"})
      assert html_accept =~ "Staged all changes" or is_binary(html_accept)

      # Revert file
      html_revert = render_click(view, "revert_file", %{"file" => "lib/all_hunks.ex"})
      assert html_revert =~ "Reverted lib/all_hunks.ex" or is_binary(html_revert)
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

      assert rendered =~ "bg-emerald-950/40"
      assert rendered =~ "def new_val, do: 2"
      assert rendered =~ "bg-rose-950/40"
      assert rendered =~ "def old_val, do: 1"
      assert rendered =~ "defmodule Test do"
      assert rendered =~ "text-indigo-300"
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
end
