defmodule IexCodeWeb.M3Round2AdversarialTest do
  use IexCode.E2E.Case, async: false
  @moduletag mock_llm: true

  import Phoenix.Component
  import Phoenix.LiveViewTest
  import IexCodeWeb.WorkspaceComponents

  # ============================================================================
  # 1. DIFF VIEWER EMPIRICAL VERIFICATION
  # ============================================================================

  describe "Diff Viewer - Code Rendering & Mode Verification" do
    test "inline mode renders exact line code and does not emit literal {line}" do
      sample_diff = """
      --- a/lib/app.ex
      +++ b/lib/app.ex
      @@ -10,4 +10,4 @@
       defmodule MyApp do
      -  def greet(name), do: "Hello " <> name
      +  def greet(name), do: "Welcome, " <> name <> "!"
       end
      """

      assigns = %{diff_text: sample_diff, diff_mode: "inline", file_path: "lib/app.ex"}

      html =
        rendered_to_string(~H"""
        <.diff_viewer diff_text={@diff_text} diff_mode={@diff_mode} file_path={@file_path} />
        """)

      # Assert exact code presence
      assert html =~ "defmodule MyApp do"

      assert html =~ "-  def greet(name), do: &quot;Hello &quot; &lt;&gt; name" or
               html =~ "-  def greet(name), do: \"Hello \" &lt;&gt; name" or
               html =~ "def greet(name)"

      assert html =~ "+  def greet(name), do:" or html =~ "Welcome, "
      refute html =~ "{line}"
      assert html =~ "border-[var(--sf-success-text)]"
      assert html =~ "bg-[color-mix(in_srgb,var(--sf-success-mark)_12%,transparent)]"
      assert html =~ "text-[var(--sf-success-text)]"
      assert html =~ "border-[var(--sf-live-mark)]"
      assert html =~ "bg-[color-mix(in_srgb,var(--sf-live-mark)_10%,transparent)]"
      assert html =~ "text-[var(--sf-live-text)]"
    end

    test "split mode renders exact line code on both sides and does not emit literal {line}" do
      sample_diff = """
      --- a/lib/calc.ex
      +++ b/lib/calc.ex
      @@ -1,5 +1,5 @@
       defmodule Calc do
      -  def subtract(x, y), do: x + y
      +  def subtract(x, y), do: x - y
       end
      """

      assigns = %{diff_text: sample_diff, diff_mode: "split", file_path: "lib/calc.ex"}

      html =
        rendered_to_string(~H"""
        <.diff_viewer diff_text={@diff_text} diff_mode={@diff_mode} file_path={@file_path} />
        """)

      # Assert split headers
      assert html =~ "Original"
      assert html =~ "Modified"

      # Assert code rendered on respective sides
      assert html =~ "def subtract(x, y), do: x + y"
      assert html =~ "def subtract(x, y), do: x - y"
      refute html =~ "{line}"
    end

    test "empty, nil, and various whitespace diffs render empty state properly" do
      whitespace_inputs = [
        "",
        nil,
        " ",
        "   ",
        "\t",
        "\n",
        "\r\n",
        "  \n\t\n  \r\n  ",
        "         \n\n\n   "
      ]

      for input <- whitespace_inputs do
        assigns = %{diff_text: input, diff_mode: "inline", file_path: nil}

        html_inline =
          rendered_to_string(~H"""
          <.diff_viewer diff_text={@diff_text} diff_mode={@diff_mode} file_path={@file_path} />
          """)

        assert html_inline =~ "No patch or diff selected."

        assigns = %{diff_text: input, diff_mode: "split", file_path: nil}

        html_split =
          rendered_to_string(~H"""
          <.diff_viewer diff_text={@diff_text} diff_mode={@diff_mode} file_path={@file_path} />
          """)

        assert html_split =~ "No patch or diff selected."
      end
    end

    test "file explorer preview correctly renders Elixir maps, tuples, and curly brackets" do
      code_with_curlies = """
      defmodule UserConfig do
        @default %{
          name: "Alice",
          roles: [:admin, :user],
          meta: {:ok, %{status: "active"}}
        }
      end
      """

      assigns = %{
        files: ["lib/user_config.ex"],
        filter: "",
        selected_file: "lib/user_config.ex",
        file_content: code_with_curlies
      }

      html =
        rendered_to_string(~H"""
        <.file_explorer
          files={@files}
          filter={@filter}
          selected_file={@selected_file}
          file_content={@file_content}
        />
        """)

      assert html =~ "UserConfig"
      assert html =~ "%{status: &quot;active&quot;}" or html =~ "%{status: \"active\"}"
      assert html =~ "roles: [:admin, :user]"
      refute html =~ "Loading file..."
    end
  end

  # ============================================================================
  # 2. PATH TRAVERSAL & SECURITY ATTACK SURFACE
  # ============================================================================

  describe "File Explorer Path Traversal & Boundary Security" do
    test "rejects traversal payloads attempting to escape project root", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      render_patch(view, "/sessions/#{session.id}?view=files")
      assert has_element?(view, "#instrument-workbench-files[data-workbench-surface='files']")

      traversal_payloads = [
        "../etc/passwd",
        "../../etc/shadow",
        "../../../etc/hosts",
        "..%2f..%2fetc%2fpasswd",
        "sub/../../secret",
        "/etc/passwd",
        "/private/etc/hosts"
      ]

      for payload <- traversal_payloads do
        # Browser URL decoding turns encoded separators into traversal segments
        # before the LiveView event reaches the server.
        event_path = URI.decode(payload)
        render_click(view, "select_file", %{"path" => event_path})
        assert has_element?(view, "#flash-error", "Invalid file path")
        assert has_element?(view, "#workspace-shell[data-active-view='files']")
        assert is_nil(:sys.get_state(view.pid).socket.assigns.selected_file)
      end
    end

    test "allows access to valid nested subdirectories inside project root", %{
      conn: conn,
      workspace_path: path
    } do
      workspace_write_file(path, "nested/deep/module.ex", "defmodule Nested.Deep.Module do end")
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      html = render_click(view, "select_file", %{"path" => "nested/deep/module.ex"})
      assert html =~ "Nested.Deep.Module"
      refute html =~ "Invalid file path"
    end
  end

  # ============================================================================
  # 3. TERMINAL RESILIENCE & ANSI STRESS
  # ============================================================================

  describe "Terminal & ANSI Resiliency" do
    test "handles malformed, nil, atom, and integer terminal PubSub messages without crashing", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      view
      |> element("#instrument-card-terminal")
      |> render_click()

      # Send various non-binary and malformed messages
      send(view.pid, {:terminal_output, session.id, nil})
      send(view.pid, {:terminal_output, session.id, :unexpected_atom})
      send(view.pid, {:terminal_output, session.id, 123_456})
      send(view.pid, {:terminal_output, session.id, %{raw: "dict"}})
      send(view.pid, {:terminal_output, session.id, ""})

      # Valid message following bad ones
      send(view.pid, {:terminal_output, session.id, "Valid terminal log line"})

      html = render(view)
      assert html =~ "Valid terminal log line"
    end

    test "ANSI parser handles shorthand reset \\e[m and dangling escape chars", %{
      conn: _conn
    } do
      text_with_m = "\e[31mError occurred\e[m Next step"
      html_res = Phoenix.HTML.safe_to_string(ansi_to_html(text_with_m))
      assert html_res =~ "text-rose-400"
      assert html_res =~ "</span> Next step"

      dangling = "Some text \e[ and \e(B and \e]0;title\a done"
      html_dangling = Phoenix.HTML.safe_to_string(ansi_to_html(dangling))
      assert html_dangling =~ "Some text"
      assert html_dangling =~ "done"
      refute html_dangling =~ "\e"
    end

    test "executes terminal command in directory with spaces in root path", %{
      conn: conn
    } do
      tmp_dir_with_space =
        Path.join(System.tmp_dir!(), "iex_code test space #{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir_with_space)
      File.write!(Path.join(tmp_dir_with_space, "space_test.txt"), "hello from space path")

      on_exit(fn -> File.rm_rf(tmp_dir_with_space) end)

      project = create_project_fixture(%{root_path: tmp_dir_with_space})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      view
      |> element("#instrument-card-terminal")
      |> render_click()

      view
      |> form("#terminal-form", %{"command" => "cat space_test.txt"})
      |> render_submit()

      html = wait_for_terminal(view, &(&1 =~ "[Exit 0: OK]"))
      assert html =~ "hello from space path"
    end
  end

  # Terminal execution is async via Port: poll until the expected output
  # (e.g. an exit marker) shows up in the rendered buffer.
  defp wait_for_terminal(view, match?, deadline \\ 2000) do
    html = render(view)

    cond do
      match?.(html) ->
        html

      deadline <= 0 ->
        flunk("timed out waiting for expected terminal output")

      true ->
        Process.sleep(50)
        wait_for_terminal(view, match?, deadline - 50)
    end
  end
end
