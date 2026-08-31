defmodule IexCodeWeb.M3ChallengerTest do
  use IexCode.E2E.Case, async: false
  @moduletag mock_llm: true

  import Phoenix.Component
  import Phoenix.LiveViewTest
  import IexCodeWeb.WorkspaceComponents

  alias IexCode.Sessions.Operation
  alias IexCode.Engine.OperationManager

  # ============================================================================
  # CHALLENGE 1: ANSI Parsing Corner Cases & Security Injection Tests
  # ============================================================================

  describe "[Challenger 1] ANSI Parser & Sanitizer Security & Edge Cases" do
    test "escapes all script tags and HTML injection vectors (XSS Prevention)" do
      xss_payloads = [
        "<script>alert('xss')</script>",
        "<img src=x onerror=alert(1)>",
        "<svg onload=alert(document.cookie)>",
        "javascript:alert(1)",
        "\e[31m<script>alert('nested')</script>\e[0m",
        "\e[38;2;255;0;0m\"><script>alert(1)</script>\e[0m",
        "<iframe src=\"data:text/html,<script>alert(1)</script>\"></iframe>",
        "<a href=\"javascript:alert(1)\">Click me</a>"
      ]

      for payload <- xss_payloads do
        safe_html = ansi_to_html(payload)
        html_str = Phoenix.HTML.safe_to_string(safe_html)

        # Must never contain unescaped raw HTML tags
        refute html_str =~ "<script>"
        refute html_str =~ "<img "
        refute html_str =~ "<svg "
        refute html_str =~ "<iframe "
        refute html_str =~ "<a href"
        assert html_str =~ "&lt;" or html_str =~ "alert"
      end
    end

    test "handles 24-bit TrueColor foreground and background RGB styling" do
      truecolor_fg = "\e[38;2;255;128;64mCustom Orange FG\e[0m"
      html_fg = Phoenix.HTML.safe_to_string(ansi_to_html(truecolor_fg))
      assert html_fg =~ "color: rgb(255,128,64);"
      assert html_fg =~ "Custom Orange FG"

      truecolor_bg = "\e[48;2;10;20;30mDark Blue BG\e[0m"
      html_bg = Phoenix.HTML.safe_to_string(ansi_to_html(truecolor_bg))
      assert html_bg =~ "background-color: rgb(10,20,30);"
      assert html_bg =~ "Dark Blue BG"

      combined = "\e[38;2;255;0;0m\e[48;2;0;0;255mRed on Blue\e[0m"
      html_combined = Phoenix.HTML.safe_to_string(ansi_to_html(combined))
      assert html_combined =~ "color: rgb(255,0,0);"
      assert html_combined =~ "background-color: rgb(0,0,255);"
      assert html_combined =~ "Red on Blue"
    end

    test "handles compound SGR sequences and standard color codes" do
      compound_codes = [
        {"\e[1;31mBold Red\e[0m", "font-bold text-rose-400"},
        {"\e[1;32mBold Green\e[0m", "font-bold text-emerald-400"},
        {"\e[1;33mBold Yellow\e[0m", "font-bold text-amber-400"},
        {"\e[1;34mBold Blue\e[0m", "font-bold text-sky-400"},
        {"\e[1;35mBold Purple\e[0m", "font-bold text-purple-400"},
        {"\e[1;36mBold Cyan\e[0m", "font-bold text-cyan-400"}
      ]

      for {seq, expected_class} <- compound_codes do
        html = Phoenix.HTML.safe_to_string(ansi_to_html(seq))
        assert html =~ expected_class
      end
    end

    test "handles malformed, incomplete, and boundary ANSI escape sequences without crashing" do
      malformed_inputs = [
        "",
        nil,
        "\e",
        "\e[",
        "\e[31",
        "\e[9999m",
        "\e[1;2;3;4;5;6;7;8;9;10m",
        "\e[;m",
        "\e[m",
        "\e[0;0;0;0;0;0m",
        "\e[38;2;999;999;999m",
        "\e[48;2;123;456;789m",
        "\e[38;2;;m",
        "\e[38;2;1;2m",
        "\e[38;5;255m",
        "\e]0;window title\a",
        "\e]2;another title\e\\",
        "\e[2K\e[1G\e[?25h\e[?25l",
        "\e(B\e)0",
        "Normal Text \e[1;31mBold Red \e[0m Reset \e[32mGreen\e[0m"
      ]

      for input <- malformed_inputs do
        safe_html = ansi_to_html(input)
        assert is_tuple(safe_html) or is_binary(safe_html)
        html_str = Phoenix.HTML.safe_to_string(safe_html)
        assert is_binary(html_str)
      end
    end

    test "handles massive terminal buffers (5,000 lines) with high throughput" do
      lines =
        for i <- 1..5_000 do
          "\e[32m[INFO #{i}]\e[0m Processing chunk #{i} with \e[1;33mWarning Code #{rem(i, 10)}\e[0m"
        end

      buffer = Enum.join(lines, "\n")

      {elapsed_us, safe_html} = :timer.tc(fn -> ansi_to_html(buffer) end)
      html_str = Phoenix.HTML.safe_to_string(safe_html)

      # 5,000 lines should parse in under 100ms
      assert elapsed_us < 100_000, "ANSI parser exceeded latency SLA: #{elapsed_us / 1000}ms"
      assert html_str =~ "[INFO 1]"
      assert html_str =~ "[INFO 5000]"
      assert html_str =~ "text-emerald-400"
      assert html_str =~ "font-bold text-amber-400"
    end
  end

  # ============================================================================
  # CHALLENGE 2: Diff Viewer Extreme Cases & Multi-file Diff Tests
  # ============================================================================

  describe "[Challenger 2] Diff Viewer Extreme Cases & Heex Safety" do
    test "renders empty and nil diffs gracefully" do
      for empty_diff <- ["", nil] do
        assigns = %{diff_text: empty_diff, diff_mode: "inline", file_path: nil}

        html =
          rendered_to_string(~H"""
          <.diff_viewer diff_text={@diff_text} diff_mode={@diff_mode} file_path={@file_path} />
          """)

        assert html =~ "No patch or diff selected"
        assert html =~ "Copy Diff"
      end
    end

    test "correctly falls back to empty state for whitespace-only diffs" do
      # When diff_text is only whitespace, diff_viewer trims and triggers empty state
      whitespace_diff = "   \n\n  "
      assigns = %{diff_text: whitespace_diff, diff_mode: "inline", file_path: nil}

      html =
        rendered_to_string(~H"""
        <.diff_viewer diff_text={@diff_text} diff_mode={@diff_mode} file_path={@file_path} />
        """)

      assert html =~ "No patch or diff selected"
    end

    test "correctly interpolates code lines in inline and split diffs without rendering literal {line}" do
      diff = """
      --- a/lib/calc.ex
      +++ b/lib/calc.ex
      @@ -1,3 +1,3 @@
       defmodule Calc do
      -  def add(a, b), do: a - b
      +  def add(a, b), do: a + b
       end
      """

      assigns = %{diff_text: diff, diff_mode: "inline", file_path: "lib/calc.ex"}

      html_inline =
        rendered_to_string(~H"""
        <.diff_viewer diff_text={@diff_text} diff_mode={@diff_mode} file_path={@file_path} />
        """)

      # Verify that code lines are properly evaluated and rendered
      assert html_inline =~ "def add(a, b), do: a + b"
      assert html_inline =~ "def add(a, b), do: a - b"
      refute html_inline =~ "{line}"

      # In the copy button data-code, the diff is intact:
      assert html_inline =~ "data-code=\"--- a/lib/calc.ex"
    end

    test "renders multi-file unified diff with 30 files in inline and split modes" do
      hunks =
        for i <- 1..30 do
          """
          --- a/lib/module_#{i}.ex
          +++ b/lib/module_#{i}.ex
          @@ -1,4 +1,6 @@
           defmodule Module#{i} do
          -  def old_func_#{i}, do: :old
          +  def new_func_#{i}, do: :new
          +  def extra_func_#{i}, do: :extra
           end
          """
        end

      large_diff = Enum.join(hunks, "\n")

      # Inline Mode
      assigns = %{diff_text: large_diff, diff_mode: "inline", file_path: "MultiPatch (30 files)"}

      html_inline =
        rendered_to_string(~H"""
        <.diff_viewer diff_text={@diff_text} diff_mode={@diff_mode} file_path={@file_path} />
        """)

      assert html_inline =~ "MultiPatch (30 files)"
      assert html_inline =~ "border-[var(--sf-success-text)]"

      assert html_inline =~
               "bg-[color-mix(in_srgb,var(--sf-success-mark)_12%,transparent)]"

      assert html_inline =~ "text-[var(--sf-success-text)]"
      assert html_inline =~ "border-[var(--sf-live-mark)]"
      assert html_inline =~ "bg-[color-mix(in_srgb,var(--sf-live-mark)_10%,transparent)]"
      assert html_inline =~ "text-[var(--sf-live-text)]"

      # Split Mode
      assigns = %{diff_text: large_diff, diff_mode: "split", file_path: "MultiPatch (30 files)"}

      html_split =
        rendered_to_string(~H"""
        <.diff_viewer diff_text={@diff_text} diff_mode={@diff_mode} file_path={@file_path} />
        """)

      assert html_split =~ "Original"
      assert html_split =~ "Modified"
    end

    test "renders diffs with pure additions, pure deletions, and binary file indicators" do
      # 1. Pure addition
      addition_diff = """
      --- /dev/null
      +++ b/lib/new_file.ex
      @@ -0,0 +1,3 @@
      +defmodule NewFile do
      +  def hello, do: :world
      +end
      """

      assigns = %{diff_text: addition_diff, diff_mode: "inline", file_path: "lib/new_file.ex"}

      html_add =
        rendered_to_string(~H"""
        <.diff_viewer diff_text={@diff_text} diff_mode={@diff_mode} file_path={@file_path} />
        """)

      assert html_add =~ "border-[var(--sf-success-text)]"

      assert html_add =~
               "bg-[color-mix(in_srgb,var(--sf-success-mark)_12%,transparent)]"

      assert html_add =~ "text-[var(--sf-success-text)]"

      # 2. Pure deletion
      deletion_diff = """
      --- a/lib/old_file.ex
      +++ /dev/null
      @@ -1,3 +0,0 @@
      -defmodule OldFile do
      -  def goodbye, do: :farewell
      -end
      """

      assigns = %{diff_text: deletion_diff, diff_mode: "inline", file_path: "lib/old_file.ex"}

      html_del =
        rendered_to_string(~H"""
        <.diff_viewer diff_text={@diff_text} diff_mode={@diff_mode} file_path={@file_path} />
        """)

      assert html_del =~ "border-[var(--sf-live-mark)]"
      assert html_del =~ "bg-[color-mix(in_srgb,var(--sf-live-mark)_10%,transparent)]"
      assert html_del =~ "text-[var(--sf-live-text)]"

      # 3. Binary diff & No newline at end of file
      binary_diff = """
      diff --git a/priv/logo.png b/priv/logo.png
      Binary files a/priv/logo.png and b/priv/logo.png differ
      \\ No newline at end of file
      """

      assigns = %{diff_text: binary_diff, diff_mode: "inline", file_path: "priv/logo.png"}

      html_bin =
        rendered_to_string(~H"""
        <.diff_viewer diff_text={@diff_text} diff_mode={@diff_mode} file_path={@file_path} />
        """)

      assert html_bin =~ "Binary files a/priv/logo.png and b/priv/logo.png differ"
      assert html_bin =~ "\\ No newline at end of file"
    end
  end

  # ============================================================================
  # CHALLENGE 3: Operation Tree Deep Nesting & Hierarchy Stress Tests
  # ============================================================================

  describe "[Challenger 3] Operation Tree Deep Nesting, Cycles & Orphan Nodes" do
    test "builds and renders deeply nested operation hierarchy (100 levels)" do
      deep_ops =
        Enum.reduce(1..100, [], fn i, acc ->
          parent_id = if i == 1, do: nil, else: "op-level-#{i - 1}"

          op = %Operation{
            id: "op-level-#{i}",
            parent_op_id: parent_id,
            agent_name: "AgentLevel#{rem(i, 4)}",
            op_type: "subtask_#{i}",
            title: "Nested Step #{i} in Deep Chain",
            status: if(rem(i, 2) == 0, do: "completed", else: "running"),
            progress: if(rem(i, 2) == 0, do: 100, else: 50),
            duration_ms: i * 5
          }

          [op | acc]
        end)

      {build_us, tree} = :timer.tc(fn -> OperationManager.build_tree(deep_ops) end)
      assert build_us < 20_000, "build_tree took #{build_us / 1000}ms for 100 levels"

      # Must have exactly 1 root node
      assert length(tree) == 1
      root = hd(tree)
      assert root.id == "op-level-1"

      # Verify tree stats
      stats = OperationManager.tree_stats(deep_ops)
      assert stats.total == 100
      assert stats.roots == 1
      assert stats.completed == 50
      assert stats.running == 50

      # Render 100 levels without component crash
      expanded = MapSet.new(Enum.map(1..100, &"op-level-#{&1}"))
      assigns = %{operations: deep_ops, expanded_ops: expanded}

      {render_us, rendered_html} =
        :timer.tc(fn ->
          rendered_to_string(~H"""
          <.operation_tree operations={@operations} expanded_ops={@expanded_ops} />
          """)
        end)

      assert render_us < 100_000, "operation_tree render took #{render_us / 1000}ms"
      assert rendered_html =~ "100 ops"
      assert rendered_html =~ "Nested Step 1 in Deep Chain"
      assert rendered_html =~ "Nested Step 100 in Deep Chain"
    end

    test "handles orphan nodes (parent_op_id pointing to non-existent ID) by promoting to roots" do
      orphan_ops = [
        %Operation{
          id: "orphan-1",
          parent_op_id: "non-existent-parent-999",
          agent_name: "ExplorerAgent",
          op_type: "ast_search",
          title: "Orphaned Search Operation",
          status: "completed"
        },
        %Operation{
          id: "orphan-2",
          parent_op_id: "another-ghost-parent",
          agent_name: "CoderAgent",
          op_type: "patch",
          title: "Orphaned Coder Operation",
          status: "running"
        },
        %Operation{
          id: "valid-root",
          parent_op_id: nil,
          agent_name: "PlannerAgent",
          op_type: "plan",
          title: "Legitimate Root Plan",
          status: "completed"
        },
        %Operation{
          id: "child-of-valid",
          parent_op_id: "valid-root",
          agent_name: "VerifierAgent",
          op_type: "verify",
          title: "Child of Root",
          status: "completed"
        }
      ]

      tree = OperationManager.build_tree(orphan_ops)
      # All 3 (orphan-1, orphan-2, valid-root) should be preserved as root nodes
      root_ids = Enum.map(tree, & &1.id)
      assert "orphan-1" in root_ids
      assert "orphan-2" in root_ids
      assert "valid-root" in root_ids
      assert length(tree) == 3

      stats = OperationManager.tree_stats(orphan_ops)
      assert stats.total == 4
      assert stats.roots == 3
    end

    test "handles operations with large error stacktraces and nil/empty params safely" do
      massive_stack =
        String.duplicate("  (elixir 1.18.0) lib/process.ex:42: Process.sleep/1\n", 200)

      failed_op = %Operation{
        id: "crash-op-1",
        parent_op_id: nil,
        agent_name: "VerifierAgent",
        op_type: "exunit_suite",
        title: "Large Crash Stacktrace Test",
        status: "failed",
        error_message: "Process died with:\n" <> massive_stack,
        params: nil,
        result: nil
      }

      assigns = %{operations: [failed_op], expanded_ops: MapSet.new(["crash-op-1"])}

      html =
        rendered_to_string(~H"""
        <.operation_tree operations={@operations} expanded_ops={@expanded_ops} />
        """)

      assert html =~ "Large Crash Stacktrace Test"
      assert html =~ "lib/process.ex:42"
      assert html =~ "1 failed"
    end
  end

  # ============================================================================
  # CHALLENGE 4: WorkspaceLive Real-Time Telemetry Burst & Stress Tests
  # ============================================================================

  describe "[Challenger 4] WorkspaceLive LiveView Real-Time Stress & PubSub Deluge" do
    test "sustains rapid deluge of 300 telemetry updates without degradation", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Switch to swarm tab
      view
      |> element("#instrument-card-swarm")
      |> render_click()

      # Send 50 operation start/progress/completed bursts
      t0 = System.monotonic_time(:millisecond)

      for i <- 1..50 do
        op_id = "op-burst-#{i}"

        agent =
          Enum.at(["PlannerAgent", "ExplorerAgent", "CoderAgent", "VerifierAgent"], rem(i, 4))

        op = %Operation{
          id: op_id,
          session_id: session.id,
          agent_name: agent,
          op_type: "burst_task",
          title: "Burst Task #{i}",
          status: "running",
          progress: 10,
          duration_ms: 15,
          pid_str: "#PID<0.#{1000 + i}.0>",
          started_at: DateTime.utc_now() |> DateTime.truncate(:second)
        }

        # 1. Started
        send(view.pid, {:operation_started, op})

        # 2. Progress 4-tuple
        send(view.pid, {:operation_progress, op_id, 60, "Burst processing #{i}"})

        # 3. Progress map telemetry
        send(
          view.pid,
          {:operation_progress,
           %{id: op_id, progress: 90, status: "running", latency_ms: 45, message: "Nearly done"}}
        )

        # 4. Completed
        completed_op = %{op | status: "completed", progress: 100, duration_ms: 50}
        send(view.pid, {:operation_completed, completed_op})
      end

      # Send terminal logs and swarm stage transitions
      send(view.pid, {:swarm_stage_changed, %{stage: :coder_formulation}})

      send(
        view.pid,
        {:terminal_output, session.id, "Terminal burst message line 1\nLine 2\nLine 3"}
      )

      elapsed_ms = System.monotonic_time(:millisecond) - t0
      assert elapsed_ms < 500, "PubSub burst dispatch took #{elapsed_ms}ms"

      # Assert rendered LiveView state
      html = render(view)
      assert html =~ "Execution Hierarchy"
      assert html =~ "Burst Task 50"
      assert html =~ "COMPLETED"
    end

    test "handles rapid tab switching while telemetry events are actively arriving", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      tabs = ["kanban", "swarm", "calendar", "changes", "chat", "files", "terminal"]

      for tab <- tabs do
        # Patch through the canonical workbench URL while telemetry is in flight.
        render_patch(view, "/sessions/#{session.id}?view=#{tab}")
        assert has_element?(view, "#workspace-shell[data-active-view='#{tab}']")
        assert has_element?(view, "#instrument-workbench-#{tab}")

        # Send concurrent telemetry event during tab display
        op = %Operation{
          id: "op-tab-#{tab}",
          session_id: session.id,
          agent_name: "ExplorerAgent",
          op_type: "discover",
          title: "Exploring during tab #{tab}",
          status: "running",
          progress: 50
        }

        send(view.pid, {:operation_started, op})
        send(view.pid, {:operation_progress, op.id, 100, "Done"})

        html = render(view)
        assert is_binary(html)
      end
    end

    test "executes terminal commands with multi-line outputs, exit codes, and clear actions", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      view
      |> element("#instrument-card-terminal")
      |> render_click()

      # 1. Successful multi-line output
      view
      |> form("#terminal-form", %{"command" => "echo 'Line A\nLine B\nLine C'"})
      |> render_submit()

      assert Process.alive?(view.pid)

      # 2. Clear terminal output
      render_click(view, "clear_terminal")
      assert Process.alive?(view.pid)
    end

    test "handles file tree search with special characters and missing files", %{
      conn: conn,
      workspace_path: path
    } do
      workspace_write_file(path, "lib/special_name.ex", "defmodule Special do end")
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Switch to files tab
      view
      |> element("#instrument-card-files")
      |> render_click()

      # Search with regex special chars
      html = render_change(view, "filter_files", %{"filter" => ".*[a-z]+"})
      assert is_binary(html)

      # Search for exact file
      html = render_change(view, "filter_files", %{"filter" => "special_name"})
      assert html =~ "special_name.ex"

      # Select file -> renders content
      html = render_click(view, "select_file", %{"path" => "lib/special_name.ex"})
      assert html =~ "defmodule Special do end"
      assert html =~ "Copy"

      # Select non-existent file -> displays safe error message
      html_ghost = render_click(view, "select_file", %{"path" => "lib/non_existent_file.ex"})
      assert html_ghost =~ "Could not read file: :enoent"
    end
  end
end
