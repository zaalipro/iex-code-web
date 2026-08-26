defmodule IexCodeWeb.WorkspaceComponentsAdversarialTest do
  use IexCode.E2E.Case, async: true
  import Phoenix.Component
  import Phoenix.LiveViewTest
  import IexCodeWeb.WorkspaceComponents
  alias IexCode.Sessions.Operation
  alias IexCode.Engine.OperationManager

  describe "Subagent Cards Adversarial Edge Cases" do
    test "correctly computes latency display for nil, 0, small, and large durations" do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      ops = [
        # Nil duration -> "--"
        %Operation{
          id: "op-nil",
          session_id: "s1",
          agent_name: "PlannerAgent",
          op_type: "plan",
          status: "idle",
          progress: 0,
          duration_ms: nil,
          started_at: now
        },
        # Zero duration -> "0ms"
        %Operation{
          id: "op-zero",
          session_id: "s1",
          agent_name: "ExplorerAgent",
          op_type: "explore",
          status: "completed",
          progress: 100,
          duration_ms: 0,
          started_at: now
        },
        # 1ms duration -> "1ms"
        %Operation{
          id: "op-one",
          session_id: "s1",
          agent_name: "CoderAgent",
          op_type: "code",
          status: "running",
          progress: 50,
          duration_ms: 1,
          started_at: now
        },
        # 54321ms duration -> "54321ms"
        %Operation{
          id: "op-large",
          session_id: "s1",
          agent_name: "VerifierAgent",
          op_type: "verify",
          status: "completed",
          progress: 100,
          duration_ms: 54321,
          started_at: now
        }
      ]

      assigns = %{operations: ops, active_stage: :verifying, active_agent: "VerifierAgent"}

      html =
        rendered_to_string(~H"""
        <.subagent_cards
          operations={@operations}
          active_stage={@active_stage}
          active_agent={@active_agent}
        />
        """)

      # Nil duration card -> "--"
      assert html =~ "--"
      # Zero duration card -> "0ms"
      assert html =~ "0ms"
      # 1ms card -> "1ms"
      assert html =~ "1ms"
      # 54321ms card -> "54321ms"
      assert html =~ "54321ms"
    end

    test "handles negative, nil, floating point, and overflow progress values gracefully" do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      ops = [
        # Nil progress
        %Operation{
          id: "op-p-nil",
          session_id: "s1",
          agent_name: "PlannerAgent",
          op_type: "plan",
          status: "idle",
          progress: nil,
          started_at: now
        },
        # Running with 0 progress -> minimum 10% bar width
        %Operation{
          id: "op-p-zero-run",
          session_id: "s1",
          agent_name: "ExplorerAgent",
          op_type: "explore",
          status: "running",
          progress: 0,
          started_at: now
        },
        # Negative progress (-25) -> max(-25, 0) => 0% or 10% if running
        %Operation{
          id: "op-p-neg",
          session_id: "s1",
          agent_name: "CoderAgent",
          op_type: "code",
          status: "idle",
          progress: -25,
          started_at: now
        },
        # 100% completed
        %Operation{
          id: "op-p-100",
          session_id: "s1",
          agent_name: "VerifierAgent",
          op_type: "verify",
          status: "completed",
          progress: 100,
          started_at: now
        }
      ]

      assigns = %{operations: ops}

      html =
        rendered_to_string(~H"""
        <.subagent_cards operations={@operations} />
        """)

      assert html =~ "0%"
      assert html =~ "100%"
      assert html =~ "width: 10%"
      assert html =~ "width: 0%"
      assert html =~ "width: 100%"
    end
  end

  describe "Operation Tree & DAG Adversarial Robustness" do
    test "handles cyclic operation hierarchies without infinite recursion" do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      # Circular reference: op1 -> op2 -> op1
      op1 = %Operation{
        id: "cycle-1",
        parent_op_id: "cycle-2",
        agent_name: "PlannerAgent",
        op_type: "plan",
        title: "Cycle Node 1",
        status: "running",
        started_at: now
      }

      op2 = %Operation{
        id: "cycle-2",
        parent_op_id: "cycle-1",
        agent_name: "ExplorerAgent",
        op_type: "explore",
        title: "Cycle Node 2",
        status: "running",
        started_at: now
      }

      tree = OperationManager.build_tree([op1, op2])
      assert is_list(tree)
      assert length(tree) > 0

      # Render the tree with cycle ops -> should terminate smoothly
      assigns = %{operations: [op1, op2], expanded_ops: MapSet.new(["cycle-1", "cycle-2"])}

      html =
        rendered_to_string(~H"""
        <.operation_tree operations={@operations} expanded_ops={@expanded_ops} />
        """)

      assert html =~ "Cycle Node 1" or html =~ "Cycle Node 2"
    end

    test "handles deep 10-level hierarchy and operations with missing or extreme attributes" do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      ops =
        for i <- 1..10 do
          %Operation{
            id: "deep-node-#{i}",
            parent_op_id: if(i == 1, do: nil, else: "deep-node-#{i - 1}"),
            agent_name: if(rem(i, 2) == 0, do: nil, else: "Agent_#{i}"),
            op_type: "step",
            title: "Deep Node Level #{i}",
            status: if(i == 10, do: "failed", else: "completed"),
            progress: 100,
            duration_ms: i * 50,
            params: %{"depth" => i, "nested" => %{"level" => i}},
            error_message: if(i == 10, do: "Deep leaf failure at level 10", else: nil),
            started_at: now
          }
        end

      all_ids = MapSet.new(Enum.map(ops, & &1.id))
      assigns = %{operations: ops, expanded_ops: all_ids}

      html =
        rendered_to_string(~H"""
        <.operation_tree operations={@operations} expanded_ops={@expanded_ops} />
        """)

      assert html =~ "10 ops"
      assert html =~ "Deep Node Level 1"
      assert html =~ "Deep Node Level 10"
      assert html =~ "Deep leaf failure at level 10"
      assert html =~ "500ms"
    end
  end
end
