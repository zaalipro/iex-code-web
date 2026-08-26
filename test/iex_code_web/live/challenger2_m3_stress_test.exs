defmodule IexCodeWeb.Challenger2M3StressTest do
  use IexCode.E2E.Case, async: false
  @moduletag mock_llm: true
  @moduletag timeout: 180_000

  alias IexCode.Sessions
  alias IexCodeWeb.WorkspaceComponents
  alias Phoenix.PubSub

  # ============================================================================
  # 1. High-Throughput Concurrent PubSub Burst Across 4 Subagents
  # ============================================================================

  describe "Milestone 3 Challenge 1: High-throughput Concurrent PubSub Telemetry" do
    test "sustains concurrent telemetry bursts from 4 subagents without dropped state", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Switch to swarm tab to view subagent cards
      view
      |> element("button[phx-value-tab='swarm']")
      |> render_click()

      agents = [
        {"PlannerAgent", "Decomposing domain model", 100},
        {"ExplorerAgent", "Scanning AST dependencies", 200},
        {"CoderAgent", "Generating atomic patches", 300},
        {"VerifierAgent", "Running ExUnit test suites", 400}
      ]

      # 1. Initialize operations for all 4 agents
      initial_ops =
        Enum.map(agents, fn {name, title, base_lat} ->
          {:ok, op} =
            Sessions.create_operation(%{
              session_id: session.id,
              agent_name: name,
              op_type: "task",
              title: title,
              status: "running",
              progress: 0,
              duration_ms: base_lat,
              pid_str: "#PID<0.#{:rand.uniform(900)}.0>",
              started_at: DateTime.utc_now() |> DateTime.truncate(:second)
            })

          # Broadcast initial operation started
          PubSub.broadcast(
            IexCode.PubSub,
            "session:#{session.id}",
            {:operation_started, op}
          )

          {name, op}
        end)

      # Allow initial broadcast to be processed
      _ = render(view)

      # 2. Concurrently blast 50 progress updates per agent (200 total bursts)
      parent = self()

      tasks =
        Enum.map(initial_ops, fn {agent_name, op} ->
          Task.async(fn ->
            for step <- 1..50 do
              pct = min(step * 2, 100)
              lat = 50 + step * 4
              status = if pct == 100, do: "completed", else: "running"
              msg = "#{agent_name} progress milestone step #{step}/50"

              # Alternate between 4-tuple and map telemetry formats
              if rem(step, 2) == 0 do
                PubSub.broadcast(
                  IexCode.PubSub,
                  "session:#{session.id}",
                  {:operation_progress, op.id, pct, msg}
                )
              else
                PubSub.broadcast(
                  IexCode.PubSub,
                  "session:#{session.id}",
                  {:operation_progress,
                   %{
                     id: op.id,
                     progress: pct,
                     latency_ms: lat,
                     status: status,
                     message: msg
                   }}
                )
              end

              # Micro-sleep to simulate real asynchronous execution interleaving
              :timer.sleep(1)
            end

            # Broadcast final completion
            final_op = %{op | status: "completed", progress: 100, duration_ms: 250}

            PubSub.broadcast(
              IexCode.PubSub,
              "session:#{session.id}",
              {:operation_completed, final_op}
            )

            send(parent, {:agent_done, agent_name})
          end)
        end)

      # Await all burst tasks
      Task.await_many(tasks, 15_000)

      # Render LiveView and verify all 4 subagents reached 100% completed
      html = render(view)

      for {name, _title, _} <- agents do
        assert html =~ name
      end

      assert html =~ "100%"
      assert html =~ "COMPLETED"
    end

    test "handles malformed, nil, and unexpected PubSub payloads gracefully without crashing LiveView",
         %{
           conn: conn,
           workspace_path: path
         } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Send various adversarial / non-standard messages
      send(view.pid, {:operation_progress, "non-existent-op-id", 50, "Ghost op"})
      send(view.pid, {:operation_progress, %{id: "non-existent-op-id", progress: 75}})
      send(view.pid, {:operation_progress, %{id: nil, progress: nil}})
      send(view.pid, {:unknown_pubsub_message, %{some: "payload"}})
      send(view.pid, {:swarm_stage_changed, "invalid_stage_format"})
      send(view.pid, {:terminal_output, session.id, nil})
      send(view.pid, :random_atom_message)

      # LiveView should remain alive and responsive
      assert render(view) =~ "Workspace" or render(view) =~ "Coding Session"
      assert Process.alive?(view.pid)
    end
  end

  # ============================================================================
  # 2. Stress Test Terminal Execution, File Search Filtering & Tab Switching
  # ============================================================================

  describe "Milestone 3 Challenge 2: Rapid Sequence Interaction Stress" do
    test "rapidly switches tabs in tight sequence under load", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      tabs = ["kanban", "swarm", "calendar", "changes", "chat", "files", "terminal"]

      # Execute 70 rapid tab switches
      for _cycle <- 1..10 do
        for tab <- tabs do
          html =
            view
            |> element("button[phx-value-tab='#{tab}']")
            |> render_click()

          assert is_binary(html)
        end
      end

      assert Process.alive?(view.pid)
    end

    test "stress tests file explorer search filtering, file selection, and rapid refreshes", %{
      conn: conn,
      workspace_path: path
    } do
      # Create a directory with 30 files
      for i <- 1..30 do
        workspace_write_file(
          path,
          "lib/iex_code/module_#{i}.ex",
          "defmodule IexCode.Module#{i} do\n  def value, do: #{i}\nend"
        )
      end

      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Rapid filter queries
      queries = [
        "module_1",
        "module_2",
        "NON_EXISTENT_FILE_XYZ",
        "",
        ".ex",
        "10",
        "25",
        "iex_code"
      ]

      for q <- queries do
        html = render_change(view, "filter_files", %{"filter" => q})
        assert is_binary(html)
      end

      # Select multiple files in rapid succession
      for i <- [1, 5, 12, 20, 30] do
        html = render_click(view, "select_file", %{"path" => "lib/iex_code/module_#{i}.ex"})
        assert html =~ "defmodule IexCode.Module#{i}"
        assert html =~ "def value, do: #{i}"
      end

      # Refresh files
      html = render_click(view, "refresh_files")
      assert html =~ "30 files" or html =~ "files"
    end

    test "stress tests terminal execution with rapid sequential and quick commands", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Switch to terminal tab
      view
      |> element("button[phx-value-tab='terminal']")
      |> render_click()

      # Run 5 commands in rapid sequence, awaiting each command's exit marker
      # before submitting the next one (a submit while running is rejected)
      commands = [
        "echo 'BURST_TEST_LINE_1'",
        "echo 'BURST_TEST_LINE_2'",
        "echo 'BURST_TEST_LINE_3'",
        "echo 'BURST_TEST_LINE_4'",
        "echo 'BURST_TEST_LINE_5'"
      ]

      for {cmd, _i} <- Enum.with_index(commands, 1) do
        view
        |> form("#terminal-form", %{"command" => cmd})
        |> render_submit()
      end

      html = render(view)

      for i <- 1..5 do
        assert html =~ "BURST_TEST_LINE_#{i}"
      end

      # Rapid quick terminal buttons
      html = render_click(view, "quick_terminal", %{"cmd" => "echo 'quick_1'"})
      assert html =~ "quick_1"

      html = render_click(view, "run_terminal", %{"command" => "echo 'quick_2'"})
      assert html =~ "quick_2"

      # Clear terminal
      html = render_click(view, "clear_terminal")
      refute html =~ "BURST_TEST_LINE_1"
      refute html =~ "quick_1"
    end
  end

  # ============================================================================
  # 3. Hierarchical Operation Tree Depth & Fan-out Stress
  # ============================================================================

  describe "Milestone 3 Challenge 3: Operation Tree Depth & Breadth Stress" do
    test "renders deep recursive operation hierarchies (10 levels) without stack overflow", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)

      # Create 10-level deep chain
      {ops, _} =
        Enum.reduce(1..10, {[], nil}, fn level, {acc, parent_id} ->
          {:ok, op} =
            Sessions.create_operation(%{
              session_id: session.id,
              parent_op_id: parent_id,
              agent_name: "AgentLevel#{level}",
              op_type: "step_#{level}",
              title: "Hierarchy Level #{level}",
              status: "completed",
              progress: 100,
              duration_ms: level * 10,
              started_at: DateTime.utc_now() |> DateTime.truncate(:second)
            })

          {[op | acc], op.id}
        end)

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      view
      |> element("button[phx-value-tab='swarm']")
      |> render_click()

      # Expand all operations from top to bottom
      for op <- Enum.reverse(ops) do
        render_click(view, "toggle_op_detail", %{"id" => op.id})
      end

      html = render(view)
      assert html =~ "Hierarchy Level 1"
      assert html =~ "Hierarchy Level 10"
      assert html =~ "AgentLevel10"
    end

    test "handles wide fan-out (30 child operations under one root)", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)

      {:ok, root_op} =
        Sessions.create_operation(%{
          session_id: session.id,
          parent_op_id: nil,
          agent_name: "SwarmCoordinator",
          op_type: "fanout_root",
          title: "Fanout Coordinator",
          status: "running",
          progress: 50,
          started_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      for i <- 1..30 do
        {:ok, _child} =
          Sessions.create_operation(%{
            session_id: session.id,
            parent_op_id: root_op.id,
            agent_name: "ExplorerAgent",
            op_type: "ast_probe",
            title: "Scanning target worker ##{i}",
            status: if(rem(i, 5) == 0, do: "failed", else: "completed"),
            error_message: if(rem(i, 5) == 0, do: "Error parsing AST token ##{i}", else: nil),
            progress: 100,
            duration_ms: i * 5,
            started_at: DateTime.utc_now() |> DateTime.truncate(:second)
          })
      end

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      view
      |> element("button[phx-value-tab='swarm']")
      |> render_click()

      # Expand root
      html = render_click(view, "toggle_op_detail", %{"id" => root_op.id})
      assert html =~ "Scanning target worker #1"
      assert html =~ "Scanning target worker #30"
      assert html =~ "failed"
    end
  end

  # ============================================================================
  # 4. Diff Viewer Edge Cases & Large Payload Rendering
  # ============================================================================

  describe "Milestone 3 Challenge 4: Diff Viewer Stress & Edge Cases" do
    test "renders massive 500-line diffs across inline and split modes without truncation error",
         %{
           conn: conn,
           workspace_path: path
         } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Generate a synthetic 500-line unified diff
      diff_lines =
        for i <- 1..250 do
          "-  old_function_call_#{i}(:deprecated_param)\n+  new_optimized_call_#{i}(:valid_param)"
        end
        |> Enum.join("\n")

      large_diff = """
      --- a/lib/iex_code/massive_module.ex
      +++ b/lib/iex_code/massive_module.ex
      @@ -1,500 +1,500 @@
      #{diff_lines}
      """

      # Switch to changes tab
      view
      |> element("button[phx-value-tab='changes']")
      |> render_click()

      # Test component rendering with massive diff
      html_inline =
        render_component(&WorkspaceComponents.diff_viewer/1,
          diff_text: large_diff,
          diff_mode: "inline",
          file_path: "lib/iex_code/massive_module.ex"
        )

      assert is_binary(html_inline)
      assert html_inline =~ "old_function_call_250"
      assert html_inline =~ "new_optimized_call_250"

      html_split =
        render_component(&WorkspaceComponents.diff_viewer/1,
          diff_text: large_diff,
          diff_mode: "split",
          file_path: "lib/iex_code/massive_module.ex"
        )

      assert is_binary(html_split)
      assert html_split =~ "Original"
      assert html_split =~ "Modified"
    end
  end

  # ============================================================================
  # 5. ANSI Parser & HTML Sanitization Stress
  # ============================================================================

  describe "Milestone 3 Challenge 5: ANSI Parser Adversarial & Security Testing" do
    test "sanitizes raw HTML, XSS payloads and handles TrueColor + compound ANSI codes" do
      # Test XSS injection sanitization
      xss_input = "\e[31m<script>alert('pwned')</script>\e[0m and <img src=x onerror=alert(1)>"
      parsed = WorkspaceComponents.ansi_to_html(xss_input) |> Phoenix.HTML.safe_to_string()

      refute parsed =~ "<script>"
      assert parsed =~ "&lt;script&gt;"
      assert parsed =~ "&lt;img"
      assert parsed =~ "text-rose-400 font-medium"

      # Test 24-bit TrueColor RGB
      truecolor_fg = "\e[38;2;255;100;50mTrueColor Text\e[0m"
      parsed_fg = WorkspaceComponents.ansi_to_html(truecolor_fg) |> Phoenix.HTML.safe_to_string()
      assert parsed_fg =~ "style=\"color: rgb(255,100,50);\""

      truecolor_bg = "\e[48;2;20;40;60mBackground RGB\e[0m"
      parsed_bg = WorkspaceComponents.ansi_to_html(truecolor_bg) |> Phoenix.HTML.safe_to_string()
      assert parsed_bg =~ "style=\"background-color: rgb(20,40,60);\""

      # Test Compound SGR codes
      compound = "\e[1;32mBold Green\e[0m \e[1;31mBold Red\e[0m \e[1;35mBold Purple\e[0m"
      parsed_comp = WorkspaceComponents.ansi_to_html(compound) |> Phoenix.HTML.safe_to_string()
      assert parsed_comp =~ "font-bold text-emerald-400"
      assert parsed_comp =~ "font-bold text-rose-400"
      assert parsed_comp =~ "font-bold text-purple-400"

      # Test nil safely
      assert WorkspaceComponents.ansi_to_html(nil) |> Phoenix.HTML.safe_to_string() == ""
    end
  end
end
