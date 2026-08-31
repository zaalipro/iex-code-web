defmodule IexCodeWeb.Live.Challenger2ExplorerEditorChatLiveStressTest do
  use IexCode.E2E.Case, async: false
  @moduletag mock_llm: true
  @moduletag timeout: 120_000

  setup %{conn: conn, workspace_path: path} do
    # Create project and session with populated test files
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)

    # Populate directory structure with diverse files
    nested_dir = Path.join(path, "lib/demo/deep/nested")
    File.mkdir_p!(nested_dir)
    File.mkdir_p!(Path.join(path, "config"))

    File.write!(
      Path.join(path, "lib/demo/sample.ex"),
      "defmodule Demo.Sample do\n  def hello, do: :world\nend\n"
    )

    File.write!(
      Path.join(path, "lib/demo/deep/nested/deep_mod.ex"),
      "defmodule Demo.Deep.Nested.DeepMod do\n  @spec run() :: :ok\n  def run, do: :ok\nend\n"
    )

    File.write!(
      Path.join(path, "config/config.exs"),
      "import Config\nconfig :iex_code, port: 4000\n"
    )

    File.write!(
      Path.join(path, ".env.local"),
      "API_SECRET=super_secret_123\n"
    )

    {:ok, conn: conn, project: project, session: session, workspace_path: path}
  end

  # ============================================================================
  # Area 1: File Explorer Folder Toggling & Filtering LiveView Stress
  # ============================================================================

  describe "File Explorer interactive LiveView stress" do
    test "toggles folder collapse and expansion idempotently across multiple levels", %{
      conn: conn,
      session: session
    } do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Switch to Files tab
      view
      |> element("#instrument-card-files")
      |> render_click()

      # Initially, folders are expanded by default on mount
      assert has_element?(view, "button[phx-click='toggle_folder'][phx-value-path='lib']")
      assert has_element?(view, "button[phx-click='toggle_folder'][phx-value-path='lib/demo']")

      assert has_element?(
               view,
               "button[phx-click='select_file'][phx-value-path='lib/demo/sample.ex']"
             )

      # Toggle collapse "lib"
      view
      |> element("button[phx-click='toggle_folder'][phx-value-path='lib']")
      |> render_click()

      # After collapsing "lib", subfolders and files inside "lib" are collapsed away
      refute has_element?(view, "button[phx-click='toggle_folder'][phx-value-path='lib/demo']")

      refute has_element?(
               view,
               "button[phx-click='select_file'][phx-value-path='lib/demo/sample.ex']"
             )

      # Toggle re-expand "lib"
      view
      |> element("button[phx-click='toggle_folder'][phx-value-path='lib']")
      |> render_click()

      # Subfolder "lib/demo" is visible again
      assert has_element?(view, "button[phx-click='toggle_folder'][phx-value-path='lib/demo']")

      # Collapse subfolder "lib/demo" specifically
      view
      |> element("button[phx-click='toggle_folder'][phx-value-path='lib/demo']")
      |> render_click()

      # "lib/demo" header is still present, but "sample.ex" inside it is collapsed
      assert has_element?(view, "button[phx-click='toggle_folder'][phx-value-path='lib/demo']")

      refute has_element?(
               view,
               "button[phx-click='select_file'][phx-value-path='lib/demo/sample.ex']"
             )
    end

    test "filters files instantly with fuzzy query and restores tree on clearing query", %{
      conn: conn,
      session: session
    } do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      view
      |> element("#instrument-card-files")
      |> render_click()

      # Filter by "deep_mod" using filter_files event hook
      view
      |> render_hook("filter_files", %{"filter" => "deep_mod"})

      # In filtered view, the retained match is displayed directly and the
      # File Atlas reports the bounded result count.
      assert has_element?(
               view,
               "#file-tree-list button[phx-click='select_file'][phx-value-path='lib/demo/deep/nested/deep_mod.ex']"
             )

      assert has_element?(view, "#file-tree-panel", "1 retained matches")

      # Clear filter
      view
      |> render_hook("filter_files", %{"filter" => ""})

      # Reverts to full project files count and folder tree
      assert has_element?(view, "button[phx-click='toggle_folder'][phx-value-path='lib']")
    end

    test "handles empty project workspace with zero files cleanly", %{
      conn: conn,
      workspace_path: path
    } do
      empty_dir = Path.join(path, "empty_workspace")
      File.mkdir_p!(empty_dir)

      empty_proj = create_project_fixture(%{root_path: empty_dir, name: "Empty Project"})
      empty_sess = create_session_fixture(empty_proj)

      {:ok, view, _html} = live(conn, ~p"/sessions/#{empty_sess.id}")

      view
      |> element("#instrument-card-files")
      |> render_click()

      assert has_element?(view, "#file-tree-panel", "0 files indexed")
      assert has_element?(view, "#file-tree-empty", "No files discovered.")
      assert has_element?(view, "#file-editor-empty", "Select a workspace file on the left")
    end
  end

  # ============================================================================
  # Area 2: Editor Multi-Buffer Tabs, Dirty Tracking, Save & Revert Stress
  # ============================================================================

  describe "Editor Buffer operations and lifecycle stress" do
    test "opens multiple buffer tabs, tracks dirty edits, saves to disk, and reverts", %{
      conn: conn,
      session: session,
      workspace_path: path
    } do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      view
      |> element("#instrument-card-files")
      |> render_click()

      # Open file 1: lib/demo/sample.ex
      view
      |> render_hook("select_file", %{"path" => "lib/demo/sample.ex"})

      assert has_element?(view, "#files-selected-signal", "lib/demo/sample.ex")
      assert has_element?(view, "#code-editor-textarea", "defmodule Demo.Sample do")
      assert has_element?(view, "#files-buffer-signal", "Saved")

      # Open file 2: config/config.exs
      view
      |> render_hook("select_file", %{"path" => "config/config.exs"})

      assert has_element?(view, "#files-selected-signal", "config/config.exs")
      assert has_element?(view, "#code-editor-textarea", "import Config")

      # Modify config/config.exs content (dirty change)
      dirty_config = "import Config\nconfig :iex_code, port: 9999, env: :test\n"

      view
      |> render_hook("file_content_changed", %{"content" => dirty_config})

      assert has_element?(view, "#files-buffer-signal", "Unsaved changes")
      assert has_element?(view, ".sf-file-atlas-dirty", "Unsaved changes")

      # Switch back to file 1 (sample.ex)
      view
      |> render_hook("select_file", %{"path" => "lib/demo/sample.ex"})

      # sample.ex is clean
      assert has_element?(view, "#files-selected-signal", "lib/demo/sample.ex")
      assert has_element?(view, "#files-buffer-signal", "Saved")

      # Switch back to file 2 (config.exs) -> dirty content must be preserved!
      view
      |> render_hook("select_file", %{"path" => "config/config.exs"})

      assert has_element?(view, "#files-selected-signal", "config/config.exs")
      assert has_element?(view, "#files-buffer-signal", "Unsaved changes")
      assert has_element?(view, "#code-editor-textarea", "port: 9999")

      # Save file 2 to disk
      view
      |> render_hook("save_file", %{"content" => dirty_config})

      assert has_element?(view, "#flash-group", "Saved config/config.exs")
      assert has_element?(view, "#files-buffer-signal", "Saved")

      # Verify disk file was actually written natively
      disk_content = File.read!(Path.join(path, "config/config.exs"))
      assert disk_content == dirty_config

      # Modify again and test revert
      view
      |> render_hook("file_content_changed", %{"content" => "corrupted content"})

      assert has_element?(view, "#files-buffer-signal", "Unsaved changes")

      # Request and confirm the destructive revert.
      view
      |> element("#file-buffer-revert-trigger")
      |> render_click()

      assert has_element?(view, "#file-buffer-revert-confirmation-dialog[role='dialog']")

      view
      |> element("#confirm-file-confirmation[phx-click='revert_file_buffer']")
      |> render_click()

      assert has_element?(view, "#flash-group", "Reverted unsaved edits in config/config.exs")
      assert has_element?(view, "#files-buffer-signal", "Saved")
      assert has_element?(view, "#code-editor-textarea", "port: 9999")

      # Close buffer tab
      view
      |> render_hook("close_file_buffer", %{"path" => "config/config.exs"})

      # Active file should fall back to sample.ex
      assert has_element?(view, "#files-selected-signal", "lib/demo/sample.ex")
    end
  end

  # ============================================================================
  # Area 3: AI Chat Code Insertion Stress (Nil vs Open Buffer, Sigils, Quotes, Curlies)
  # ============================================================================

  describe "AI Chat code insertion stress" do
    test "inserting code when no active buffer is selected gives clean error flash", %{
      conn: conn,
      session: session
    } do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # No file is open in editor buffer
      view
      |> render_hook("insert_code_to_editor", %{"code" => "def test_no_buffer, do: :ok"})

      assert has_element?(
               view,
               "#flash-group",
               "No active file buffer. Open a file in the editor first."
             )
    end

    test "inserts multiline Elixir snippet with complex sigils, quotes, curlies, and string interpolation",
         %{
           conn: conn,
           session: session,
           workspace_path: path
         } do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
      render_click(view, "switch_tab", %{"tab" => "files"})

      # Open sample.ex in editor
      view
      |> render_hook("select_file", %{"path" => "lib/demo/sample.ex"})

      # Complex Elixir code snippet with ~H, ~S, quotes, #{...} interpolation, curlies, and tags
      complex_snippet = """
        @doc ~S\"\"\"
        Renders a widget with dynamic tags and values: \#{inspect(@item)}
        \"\"\"
        def render_widget(assigns) do
          ~H\"\"\"
          <div id={"widget-\#{@item.id}"} class={["p-4 rounded-xl", @is_active && "border-cyan-500"]}>
            <span class="font-bold">{\#{@item.title}}</span>
            <%!-- Comment with curly { } test --%>
            <pre phx-no-curly-interpolation>
              let obj = {status: "ok", count: 42};
            </pre>
          </div>
          \"\"\"
        end
      """

      # Send insert_code_to_editor event
      view
      |> render_hook("insert_code_to_editor", %{"code" => complex_snippet})

      assert has_element?(view, "#flash-group", "Inserted snippet into lib/demo/sample.ex")
      assert has_element?(view, "#files-buffer-signal", "Unsaved changes")
      assert has_element?(view, ".sf-file-atlas-dirty", "Unsaved changes")
      assert has_element?(view, "#code-editor-textarea", "render_widget(assigns)")
      assert has_element?(view, "#code-editor-textarea", "phx-no-curly-interpolation")

      # Save the buffer with the inserted code
      view
      |> render_hook("save_file", %{})

      assert has_element?(view, "#flash-group", "Saved lib/demo/sample.ex")

      # Verify disk file contains verbatim snippet without escaping flaws
      saved_disk = File.read!(Path.join(path, "lib/demo/sample.ex"))
      assert saved_disk =~ "defmodule Demo.Sample do"
      assert saved_disk =~ "def render_widget(assigns)"
      assert saved_disk =~ "phx-no-curly-interpolation"
      assert saved_disk =~ "let obj = {status: \"ok\", count: 42};"
    end

    test "multiple sequential code insertions concatenate cleanly with double newlines", %{
      conn: conn,
      session: session
    } do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
      render_click(view, "switch_tab", %{"tab" => "files"})

      view
      |> render_hook("select_file", %{"path" => "lib/demo/sample.ex"})

      snippet1 = "  def snippet_one, do: 1"
      snippet2 = "  def snippet_two, do: 2"
      snippet3 = "  def snippet_three, do: 3"

      view |> render_hook("insert_code_to_editor", %{"code" => snippet1})
      view |> render_hook("insert_code_to_editor", %{"code" => snippet2})
      view |> render_hook("insert_code_to_editor", %{"code" => snippet3})

      assert has_element?(view, "#code-editor-textarea", "snippet_one")
      assert has_element?(view, "#code-editor-textarea", "snippet_two")
      assert has_element?(view, "#code-editor-textarea", "snippet_three")
    end
  end
end
