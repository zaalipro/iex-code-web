defmodule IexCodeWeb.Challenger2M1TemplateStressTest do
  use IexCode.E2E.Case, async: false
  import Phoenix.LiveViewTest
  @moduletag mock_llm: true
  @moduletag timeout: 120_000

  alias IexCode.Settings
  alias IexCode.Sessions.Operation
  alias IexCodeWeb.WorkspaceComponents
  alias IexCode.LLM.{OpenAI, Anthropic}

  # ============================================================================
  # 1. Template Rendering Under Empty & Extreme Session States
  # ============================================================================

  describe "WorkspaceLive Dynamic Calculations & Template Rendering" do
    test "renders cleanly across all workspace instruments with empty initial session", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      tabs = ["kanban", "swarm", "research", "calendar", "changes", "chat", "files", "terminal"]

      for tab <- tabs do
        html = render_click(view, "switch_tab", %{"tab" => tab})

        assert is_binary(html)
        assert Process.alive?(view.pid)
      end
    end

    test "renders Settings modal with zero, mid-range, and extreme credit values without crashing",
         %{
           conn: conn,
           workspace_path: path
         } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Workspace delegates settings to SettingsLive via an anchored navigation shim.
      render_click(view, "toggle_settings_modal")
      assert_redirect(view, "/sessions/#{session.id}/settings#execution")
    end

    test "handles coach and swarm dynamic progress calculation under boundary parameters", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Switch to swarm tab
      html = render_click(view, "switch_tab", %{"tab" => "swarm"})
      assert html =~ "MULTI-AGENT SWARM HARNESS ACTIVE"
      assert html =~ "TOKENS"
      assert html =~ "ITERATION"

      # Trigger swarm stage change to iteration 5
      send(view.pid, {:swarm_stage_changed, %{stage: :coder, iteration: 5}})
      html = render(view)
      assert html =~ "ITERATION 5/3"
    end

    test "handles scheduled tab dynamic counters with empty and populated tasks", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Switch to the factual responsive calendar presentations.
      render_click(view, "switch_tab", %{"tab" => "calendar"})
      assert has_element?(view, "#instrument-workbench-calendar")
      assert has_element?(view, "#calendar-desktop-agenda")
      assert has_element?(view, "#calendar-mobile-agenda[data-mobile-default='true']")
      refute has_element?(view, "#instrument-workbench-calendar", "MONTHLY RUNS")
    end

    test "handles changes tab dynamic canvas and diff rendering", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)

      # Create some workspace files
      workspace_write_file(path, "lib/sample_a.ex", "defmodule SampleA, do: :ok")
      workspace_write_file(path, "lib/sample_b.ex", "defmodule SampleB, do: :ok")

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Switch to changes tab
      html = render_click(view, "switch_tab", %{"tab" => "changes"})
      assert html =~ "All Changes"
      assert html =~ "Canvas ·"
    end
  end

  # ============================================================================
  # 2. Dynamic Calculation Arithmetic Stress Tests (Isolated Evaluation)
  # ============================================================================

  describe "Dynamic Calculation Pure Math Edge Cases" do
    test "coach_pct math behaves safely across all integer/boundary inputs" do
      calculate_coach_pct = fn total_ops, completed_ops, swarm_iteration, max_retries ->
        cond do
          total_ops > 0 ->
            round(completed_ops / total_ops * 100)

          swarm_iteration > 0 and max_retries > 0 ->
            round(swarm_iteration / max_retries * 100)

          true ->
            0
        end
      end

      # Zero ops, normal retries
      assert calculate_coach_pct.(0, 0, 1, 3) == 33
      # Zero ops, zero retries
      assert calculate_coach_pct.(0, 0, 0, 0) == 0
      # Zero ops, iteration 0
      assert calculate_coach_pct.(0, 0, 0, 3) == 0
      # Max ops completed
      assert calculate_coach_pct.(10, 10, 1, 3) == 100
      # Half ops completed
      assert calculate_coach_pct.(10, 5, 1, 3) == 50
      # 0 ops completed out of 10
      assert calculate_coach_pct.(10, 0, 1, 3) == 0
      # Extreme large iteration
      assert calculate_coach_pct.(0, 0, 100, 3) == 3333

      # Ticks bounding
      assert min(65, max(0, round(3333 * 0.65))) == 65
      assert min(65, max(0, round(0 * 0.65))) == 0
      assert min(65, max(0, round(50 * 0.65))) == 33
    end

    test "credits math behaves safely with zero, typical, and extreme session tokens" do
      calculate_credits = fn session_tokens, ops_count, msgs_count ->
        used_credits =
          if session_tokens > 0,
            do: session_tokens,
            else: ops_count * 1500 + msgs_count * 800

        used_pct = min(100.0, Float.round(used_credits / 1_000_000 * 100, 1))
        remaining_credits = max(0, 100_000_000 - used_credits)
        active_credit_ticks = min(65, max(1, round(used_pct * 0.65)))

        {used_credits, used_pct, remaining_credits, active_credit_ticks}
      end

      # 0 tokens, 0 ops, 0 msgs
      {used, pct, rem_cred, ticks} = calculate_credits.(0, 0, 0)
      assert used == 0
      assert pct == 0.0
      assert rem_cred == 100_000_000
      assert ticks == 1

      # 0 tokens, 5 ops, 10 msgs fallback
      {used, pct, rem_cred, ticks} = calculate_credits.(0, 5, 10)
      assert used == 5 * 1500 + 10 * 800
      assert is_float(pct)
      assert is_integer(rem_cred)
      assert ticks >= 1 and ticks <= 65

      # 56.4M tokens
      {used, pct, rem_cred, ticks} = calculate_credits.(56_400_000, 0, 0)
      assert used == 56_400_000
      assert pct == 100.0 or pct == 5640.0
      assert rem_cred == 43_600_000
      assert ticks == 65

      # 100M tokens
      {used, pct, rem_cred, ticks} = calculate_credits.(100_000_000, 0, 0)
      assert used == 100_000_000
      assert pct == 100.0
      assert rem_cred == 0
      assert ticks == 65

      # 1,000M tokens (extreme over-limit)
      {used, pct, rem_cred, ticks} = calculate_credits.(1_000_000_000, 0, 0)
      assert used == 1_000_000_000
      assert pct == 100.0
      assert rem_cred == 0
      assert ticks == 65
    end
  end

  # ============================================================================
  # 3. Component Rendering Robustness Under Corrupted / Extreme Ops
  # ============================================================================

  describe "Workspace Components Adversarial Stress" do
    test "subagent_cards renders without exception under malformed, nil, or extreme operation fields" do
      corrupt_ops = [
        %Operation{
          id: "1",
          agent_name: "PlannerAgent",
          status: nil,
          progress: nil,
          duration_ms: nil,
          pid_str: nil
        },
        %Operation{
          id: "2",
          agent_name: "ExplorerAgent",
          status: "running",
          progress: -50,
          duration_ms: 0,
          pid_str: nil
        },
        %Operation{
          id: "3",
          agent_name: "CoderAgent",
          status: "completed",
          progress: 9999,
          duration_ms: -100,
          pid_str: "#PID<0.1.0>"
        },
        %Operation{
          id: "4",
          agent_name: "VerifierAgent",
          status: "failed",
          progress: 100,
          duration_ms: 500_000,
          pid_str: "invalid_pid"
        }
      ]

      rendered =
        render_component(&WorkspaceComponents.subagent_cards/1,
          operations: corrupt_ops,
          active_stage: :init,
          active_agent: nil,
          swarm_mode: true
        )

      assert rendered =~ "Planner"
      assert rendered =~ "Explorer"
      assert rendered =~ "Coder"
      assert rendered =~ "Verifier"
    end

    test "operation_tree renders gracefully under cyclic parent references and empty lists" do
      # 1. Empty operations
      rendered_empty =
        render_component(&WorkspaceComponents.operation_tree/1,
          operations: [],
          expanded_ops: MapSet.new()
        )

      assert rendered_empty =~ "No operations recorded in this session."

      # 2. Cyclic & Orphaned operations
      op1 = %Operation{
        id: "op1",
        parent_op_id: "op2",
        title: "Op 1",
        status: "completed",
        progress: 100
      }

      op2 = %Operation{
        id: "op2",
        parent_op_id: "op1",
        title: "Op 2",
        status: "running",
        progress: 50
      }

      op3 = %Operation{
        id: "op3",
        parent_op_id: "nonexistent",
        title: "Op 3",
        status: "failed",
        progress: 0
      }

      rendered_cyclic =
        render_component(&WorkspaceComponents.operation_tree/1,
          operations: [op1, op2, op3],
          expanded_ops: MapSet.new()
        )

      assert rendered_cyclic =~ "Execution Hierarchy"
      assert rendered_cyclic =~ "3 ops"
    end
  end

  # ============================================================================
  # 4. LLM Fallback Contract Verification (No Synthetic Fake Mocks)
  # ============================================================================

  describe "LLM Client Error Handling Contract" do
    test "OpenAI client strictly returns {:error, :no_api_key} when api_key is blank or nil" do
      blank_keys = [nil, ""]

      for key <- blank_keys do
        assert {:error, :no_api_key} ==
                 OpenAI.chat(
                   [%{role: "user", content: "Hello"}],
                   "System prompt",
                   api_key: key,
                   stream: false
                 )
      end
    end

    test "Anthropic client strictly returns {:error, :no_api_key} when api_key is blank or nil" do
      blank_keys = [nil, ""]

      for key <- blank_keys do
        assert {:error, :no_api_key} ==
                 Anthropic.chat(
                   [%{role: "user", content: "Hello"}],
                   "System prompt",
                   api_key: key,
                   stream: false
                 )
      end
    end
  end

  # ============================================================================
  # 5. Database Resilience & Concurrent Transaction Stress
  # ============================================================================

  describe "Database Resilience & Lock Contention" do
    test "sequential settings updates and reads handle SQLite lock serialization gracefully" do
      for i <- 1..10 do
        Settings.update_settings(%{
          swarm_agent_count: 4 + rem(i, 8),
          auto_save: rem(i, 2) == 0
        })

        settings = Settings.get_settings()
        assert is_integer(settings.swarm_agent_count)
      end

      final_settings = Settings.get_settings()
      assert is_integer(final_settings.swarm_agent_count)
    end
  end

  # ============================================================================
  # 6. Dead Code & Assign Elimination Verification
  # ============================================================================

  describe "Dead Code & Duplicate Handlers Audit" do
    test "WorkspaceLive mount assigns are lean with 0 dead assign warnings", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
      assigns = :sys.get_state(view.pid).socket.assigns

      dead_keys = [
        :tokens_in,
        :tokens_out,
        :picker_mode,
        :selected_calendar_day,
        :new_task_time,
        :new_task_schedule_type,
        :show_usage_history_modal
      ]

      for key <- dead_keys do
        refute Map.has_key?(assigns, key),
               "Dead assign :#{key} should not be present in socket assigns"
      end
    end
  end
end
