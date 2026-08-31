defmodule IexCodeWeb.Challenger4M3StressTest do
  use IexCode.E2E.Case, async: false
  @moduletag mock_llm: true

  alias IexCode.Sessions
  alias IexCode.Sessions.Operation
  alias IexCodeWeb.WorkspaceComponents
  alias Phoenix.PubSub

  # ============================================================================
  # 1. High-Throughput 4-Subagent Concurrent PubSub Burst
  # ============================================================================

  describe "[Challenger 4] Concurrency Stress: 4 Subagents Rapid PubSub Deluge" do
    test "sustains 400 concurrent telemetry events across 4 subagents without dropped state or race condition",
         %{
           conn: conn,
           workspace_path: path
         } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Navigate to swarm view
      view
      |> element("#instrument-card-swarm")
      |> render_click()

      subagents = [
        {"PlannerAgent", "Decomposing domain specifications", 120},
        {"ExplorerAgent", "Indexing symbol definitions and AST", 180},
        {"CoderAgent", "Synthesizing multi-file atomic patches", 240},
        {"VerifierAgent", "Running ExUnit test suites and AutoFix", 300}
      ]

      # 1. Initialize operations in DB
      initial_ops =
        Enum.map(subagents, fn {name, desc, lat} ->
          {:ok, op} =
            Sessions.create_operation(%{
              session_id: session.id,
              agent_name: name,
              op_type: "pipeline_stage",
              title: desc,
              status: "running",
              progress: 0,
              duration_ms: lat,
              pid_str: "#PID<0.#{:rand.uniform(9999)}.0>",
              started_at: DateTime.utc_now() |> DateTime.truncate(:second)
            })

          PubSub.broadcast(IexCode.PubSub, "session:#{session.id}", {:operation_started, op})
          {name, op}
        end)

      # 2. Concurrently blast 100 telemetry events per agent in parallel Tasks (400 total events)
      parent = self()

      tasks =
        Enum.map(initial_ops, fn {name, op} ->
          Task.async(fn ->
            for step <- 1..100 do
              pct = step
              lat = 20 + step * 2
              msg = "#{name} step #{step}/100 active execution"

              case rem(step, 4) do
                0 ->
                  # Standard 4-tuple
                  PubSub.broadcast(
                    IexCode.PubSub,
                    "session:#{session.id}",
                    {:operation_progress, op.id, pct, msg}
                  )

                1 ->
                  # Map telemetry with latency and message
                  PubSub.broadcast(
                    IexCode.PubSub,
                    "session:#{session.id}",
                    {:operation_progress,
                     %{
                       id: op.id,
                       progress: pct,
                       latency_ms: lat,
                       status: "running",
                       message: msg
                     }}
                  )

                2 ->
                  # Swarm stage update interleaved
                  stage =
                    case rem(step, 3) do
                      0 -> :planner_decomposition
                      1 -> :explorer_discovery
                      _ -> :coder_formulation
                    end

                  PubSub.broadcast(
                    IexCode.PubSub,
                    "session:#{session.id}",
                    {:swarm_stage_changed, %{stage: stage}}
                  )

                3 ->
                  # Terminal telemetry snippet interleaved
                  PubSub.broadcast(
                    IexCode.PubSub,
                    "session:#{session.id}",
                    {:terminal_output, session.id, "[#{name}] Log entry ##{step}"}
                  )
              end

              # Micro delay to interleave VM schedulers
              :timer.sleep(1)
            end

            # Broadcast final completion
            completed_op = %{op | status: "completed", progress: 100, duration_ms: 220}

            PubSub.broadcast(
              IexCode.PubSub,
              "session:#{session.id}",
              {:operation_completed, completed_op}
            )

            send(parent, {:agent_done, name})
          end)
        end)

      Task.await_many(tasks, 15_000)

      # Verify LiveView process survived and rendered all 4 subagents at 100% completed
      assert Process.alive?(view.pid)
      html = render(view)

      for {name, _, _} <- subagents do
        assert html =~ name
      end

      assert html =~ "100%"
      assert html =~ "COMPLETED"
    end

    test "multi-client broadcast: 2 LiveViews maintain synchronized state under 4-agent burst",
         %{
           conn: conn,
           workspace_path: path
         } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)

      {:ok, view1, _} = live(conn, ~p"/sessions/#{session.id}")
      {:ok, view2, _} = live(conn, ~p"/sessions/#{session.id}")

      # Both views switch to swarm tab
      view1 |> element("#instrument-card-swarm") |> render_click()
      view2 |> element("#instrument-card-swarm") |> render_click()

      # Create 4 operations
      agents = ["PlannerAgent", "ExplorerAgent", "CoderAgent", "VerifierAgent"]

      ops =
        Enum.map(agents, fn name ->
          {:ok, op} =
            Sessions.create_operation(%{
              session_id: session.id,
              agent_name: name,
              op_type: "parallel_task",
              title: "Testing #{name}",
              status: "running",
              progress: 0,
              started_at: DateTime.utc_now() |> DateTime.truncate(:second)
            })

          PubSub.broadcast(IexCode.PubSub, "session:#{session.id}", {:operation_started, op})
          op
        end)

      # Burst 25 updates per agent
      tasks =
        Enum.map(ops, fn op ->
          Task.async(fn ->
            for step <- 1..25 do
              PubSub.broadcast(
                IexCode.PubSub,
                "session:#{session.id}",
                {:operation_progress,
                 %{
                   id: op.id,
                   progress: step * 4,
                   latency_ms: step * 5,
                   status: if(step == 25, do: "completed", else: "running"),
                   message: "Progress #{step * 4}%"
                 }}
              )

              :timer.sleep(1)
            end
          end)
        end)

      Task.await_many(tasks, 10_000)

      # Both LiveViews must be alive and render updated state
      assert Process.alive?(view1.pid)
      assert Process.alive?(view2.pid)

      html1 = render(view1)
      html2 = render(view2)

      for name <- agents do
        assert html1 =~ name
        assert html2 =~ name
      end

      assert html1 =~ "100%"
      assert html2 =~ "100%"
    end
  end

  # ============================================================================
  # 2. Nil Crash Resilience & Adversarial PubSub Payloads
  # ============================================================================

  describe "[Challenger 4] Nil & Adversarial Crash Resilience" do
    test "resilient to nil, empty, malformed and unexpected terminal output payloads", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Send dangerous / non-binary payloads for terminal_output
      adversarial_terminal_messages = [
        {:terminal_output, session.id, nil},
        {:terminal_output, session.id, ""},
        {:terminal_output, session.id, 12_345},
        {:terminal_output, session.id, :not_a_binary_atom},
        {:terminal_output, session.id, ["list", "of", "strings"]},
        {:terminal_output, session.id, %{text: "nested map"}},
        {:terminal_output, session.id, {:tuple, "payload"}},
        {:terminal_output, session.id, fn -> :dangerous_function end},
        {:terminal_output, nil, nil},
        {:terminal_output, "invalid-session-id", "Valid text for invalid session"}
      ]

      for msg <- adversarial_terminal_messages do
        send(view.pid, msg)
      end

      # LiveView must remain alive and responsive
      assert Process.alive?(view.pid)
      assert render(view) =~ "Workspace" or render(view) =~ "Coding Session"

      # Send a valid terminal output and verify it renders properly
      send(view.pid, {:terminal_output, session.id, "RECOVERY_OUTPUT_AFTER_NIL_TEST"})
      _ = :sys.get_state(view.pid)

      assert_push_event(view, "terminal_output", %{data: "RECOVERY_OUTPUT_AFTER_NIL_TEST"})

      view |> element("#instrument-card-terminal") |> render_click()

      assert has_element?(
               view,
               "#terminal-rendered-output.hidden",
               "RECOVERY_OUTPUT_AFTER_NIL_TEST"
             )
    end

    test "resilient to nil fields in operations and telemetry maps", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # View swarm tab
      view |> element("#instrument-card-swarm") |> render_click()

      # Operation struct with all fields nil except ID
      op_with_nils = %Operation{
        id: "op-with-all-nils",
        session_id: session.id,
        parent_op_id: nil,
        agent_name: nil,
        op_type: nil,
        title: nil,
        status: nil,
        progress: nil,
        duration_ms: nil,
        result: nil,
        error_message: nil,
        pid_str: nil
      }

      send(
        view.pid,
        {:operation_started,
         %Operation{
           id: "op-nil-status",
           session_id: session.id,
           agent_name: "PlannerAgent",
           status: nil
         }}
      )

      send(view.pid, {:operation_started, op_with_nils})
      send(view.pid, {:operation_updated, op_with_nils})
      send(view.pid, {:operation_completed, op_with_nils})
      send(view.pid, {:operation_failed, op_with_nils})

      # Map telemetry with nils and missing keys
      send(view.pid, {:operation_progress, %{id: nil, progress: nil}})
      send(view.pid, {:operation_progress, %{id: "op-with-all-nils", progress: nil, status: nil}})

      send(
        view.pid,
        {:operation_progress,
         %{id: "op-with-all-nils", progress: 50, latency_ms: nil, message: nil}}
      )

      send(view.pid, {:operation_progress, "op-with-all-nils", nil, nil})
      send(view.pid, {:operation_progress, "op-with-all-nils", 75, nil})

      # Stage changes with nil/invalid formats
      send(view.pid, {:swarm_stage_changed, nil})
      send(view.pid, {:swarm_stage_changed, %{stage: nil}})
      send(view.pid, {:swarm_stage_changed, %{}})
      send(view.pid, {:swarm_stage_changed, "not_an_atom"})
      send(view.pid, {:swarm_stage_changed, 42})

      # Session status changes
      send(view.pid, {:session_status_changed, nil})
      send(view.pid, {:session_status_changed, "active"})

      # Tasks with nil / empty fields
      send(
        view.pid,
        {:task_created,
         %IexCode.Kanban.Task{
           id: "t-empty-assignee",
           title: "Task with empty assignee",
           assignee: "",
           status: "triage"
         }}
      )

      send(view.pid, {:task_created, %IexCode.Kanban.Task{id: "t-nil", title: nil, status: nil}})
      send(view.pid, {:task_updated, %IexCode.Kanban.Task{id: "t-nil", title: nil, status: nil}})
      send(view.pid, {:task_deleted, %IexCode.Kanban.Task{id: "t-nil"}})

      # Unknown messages
      send(view.pid, :unknown_atomic_event)
      send(view.pid, {:unknown_tuple, 1, 2, 3})
      send(view.pid, %{unhandled: "map"})

      # Ensure process is intact and rendering does not raise KeyError/ArgumentError
      assert Process.alive?(view.pid)
      html = render(view)
      assert is_binary(html)
      assert html =~ "Swarm" or html =~ "Operations"
    end

    test "component functions handle nil parameters gracefully without raising", %{
      workspace_path: _path
    } do
      # 1. diff_viewer with nil values
      html_diff =
        render_component(&WorkspaceComponents.diff_viewer/1,
          diff_text: nil,
          diff_mode: nil,
          file_path: nil
        )

      assert html_diff =~ "No patch or diff selected"

      # 2. subagent_cards with empty and nil operations
      html_cards_empty =
        render_component(&WorkspaceComponents.subagent_cards/1,
          operations: [],
          active_stage: nil,
          active_agent: nil
        )

      assert html_cards_empty =~ "Planner"
      assert html_cards_empty =~ "Explorer"
      assert html_cards_empty =~ "Coder"
      assert html_cards_empty =~ "Verifier"

      # 3. subagent_cards with nil fields in operations
      nil_op = %Operation{
        id: "nil-op",
        agent_name: "PlannerAgent",
        status: nil,
        progress: nil,
        duration_ms: nil,
        title: nil,
        result: nil,
        pid_str: nil
      }

      html_cards_nils =
        render_component(&WorkspaceComponents.subagent_cards/1,
          operations: [nil_op],
          active_stage: :init,
          active_agent: nil
        )

      assert html_cards_nils =~ "Planner"
      assert html_cards_nils =~ "0%"

      # 4. ansi_to_html with nil
      assert WorkspaceComponents.ansi_to_html(nil) |> Phoenix.HTML.safe_to_string() == ""

      # 5. operation_tree with nil / cycle parent_op_id
      cycle_ops = [
        %Operation{
          id: "cycle-1",
          parent_op_id: "cycle-2",
          agent_name: "A",
          title: "Node 1",
          status: "running"
        },
        %Operation{
          id: "cycle-2",
          parent_op_id: "cycle-1",
          agent_name: "B",
          title: "Node 2",
          status: "completed"
        }
      ]

      html_tree =
        render_component(&WorkspaceComponents.operation_tree/1,
          operations: cycle_ops,
          expanded_ops: MapSet.new(["cycle-1", "cycle-2"])
        )

      assert html_tree =~ "Node 1" or html_tree =~ "Node 2"
    end
  end

  # ============================================================================
  # 3. Interactive Concurrency Under Telemetry Load
  # ============================================================================

  describe "[Challenger 4] User Interaction Under Simultaneous Telemetry Stream" do
    test "processes terminal commands and file selections while PubSub updates arrive asynchronously",
         %{
           conn: conn,
           workspace_path: path
         } do
      # Set up files
      workspace_write_file(
        path,
        "lib/active_module.ex",
        "defmodule ActiveModule do def run, do: :ok end"
      )

      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Start background task flooding PubSub
      parent = self()

      flood_task =
        Task.async(fn ->
          for i <- 1..50 do
            PubSub.broadcast(
              IexCode.PubSub,
              "session:#{session.id}",
              {:terminal_output, session.id, "Stream background log ##{i}"}
            )

            PubSub.broadcast(
              IexCode.PubSub,
              "session:#{session.id}",
              {:operation_progress, %{id: "async-op", progress: i * 2, status: "running"}}
            )

            :timer.sleep(2)
          end

          send(parent, :flood_complete)
        end)

      # Concurrently interact with the LiveView
      # 1. Open Terminal Scope from the canonical Instrument Deck
      view |> element("#instrument-card-terminal") |> render_click()

      # 2. Run terminal command
      view
      |> form("#terminal-form", %{"command" => "echo 'INTERACTIVE_TERMINAL_CMD_SUCCESS'"})
      |> render_submit()

      assert has_element?(
               view,
               "#terminal-rendered-output.hidden",
               "INTERACTIVE_TERMINAL_CMD_SUCCESS"
             )

      # 3. Return through the deck before opening File Atlas and selecting a file
      view |> element("#return-to-instrument-deck-terminal") |> render_click()
      view |> element("#instrument-card-files") |> render_click()
      html_file = render_click(view, "select_file", %{"path" => "lib/active_module.ex"})
      assert html_file =~ "defmodule ActiveModule"

      # Wait for background flood
      Task.await(flood_task, 5_000)
      _ = :sys.get_state(view.pid)

      assert_push_event(view, "terminal_output", %{data: "Stream background log #50"})

      assert has_element?(
               view,
               "#instrument-workbench-terminal[hidden] #terminal-rendered-output.hidden",
               "Stream background log #50"
             )

      # Verify LiveView process state remains consistent
      assert Process.alive?(view.pid)
    end
  end
end
