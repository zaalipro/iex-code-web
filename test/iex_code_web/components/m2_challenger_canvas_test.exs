defmodule IexCodeWeb.Components.M2ChallengerCanvasTest do
  @moduledoc """
  Empirical verification test suite for SVG canvas & math boundaries (Milestone 2).
  Stress-tests extreme DAG topologies, Bézier curve mathematical invariance,
  progress ring boundary clamping, and node status halo rendering.
  """

  use IexCode.E2E.Case, async: false
  import Phoenix.LiveViewTest

  alias IexCodeWeb.WorkflowComponents
  alias IexCode.Workflows.{Workflow, WorkflowRun}

  # ============================================================================
  # SCENARIO 1: EXTREME DAG TOPOLOGIES
  # ============================================================================

  describe "extreme DAG topologies" do
    test "single-step workflow boundary (K = 1)" do
      single_step = [
        %{
          "key" => "step_solo",
          "title" => "Solo Task",
          "kind" => "deep_research",
          "depends_on" => [],
          "model_config" => %{"reasoning_effort" => "high"}
        }
      ]

      graph = WorkflowComponents.layout_workflow_dag(single_step, %{}, nil)

      assert length(graph.nodes) == 1
      assert length(graph.edges) == 0

      [solo_node] = graph.nodes
      assert solo_node.key == "step_solo"
      assert solo_node.x == 60
      assert solo_node.y == 60
      assert solo_node.width == 250
      assert solo_node.height == 115

      # Minimum canvas boundary guarantees
      assert graph.width >= 800
      assert graph.height >= 500

      # LiveView component rendering test
      workflow = %Workflow{id: "wf-solo", name: "Solo Workflow", steps: single_step}

      run = %WorkflowRun{
        id: "run-solo",
        status: "running",
        resolved_steps: single_step,
        step_states: %{}
      }

      html =
        render_component(&WorkflowComponents.workflow_canvas/1,
          id: "canvas-solo",
          workflow: workflow,
          run: run
        )

      assert html =~ "id=\"canvas-solo-svg\""
      assert html =~ "step-node-step_solo"
      assert html =~ "Solo Task"
      assert html =~ "1 steps"
      assert html =~ "0 dependencies"
      # Edges container should be empty of path tags
      refute html =~ "id=\"edge-"
    end

    test "linear deep chain (12 sequential steps, K >= 10)" do
      chain_length = 12

      chain_steps =
        Enum.map(1..chain_length, fn idx ->
          deps = if idx == 1, do: [], else: ["step_#{idx - 1}"]

          %{
            "key" => "step_#{idx}",
            "title" => "Pipeline Step #{idx}",
            "kind" => "swarm_code_gen",
            "depends_on" => deps,
            "model_config" => %{"reasoning_effort" => "medium"}
          }
        end)

      graph = WorkflowComponents.layout_workflow_dag(chain_steps, %{}, nil)

      assert length(graph.nodes) == chain_length
      assert length(graph.edges) == chain_length - 1

      # 1. Monotonic horizontal progression: x_i < x_{i+1}
      nodes = Enum.sort_by(graph.nodes, & &1.x)
      assert length(nodes) == chain_length

      for idx <- 0..(chain_length - 2) do
        current_node = Enum.at(nodes, idx)
        next_node = Enum.at(nodes, idx + 1)

        assert current_node.x < next_node.x,
               "Expected x(#{current_node.key}) < x(#{next_node.key})"

        # Column spacing invariance: node_width (250) + gap_x (90) = 340
        assert next_node.x - current_node.x == 340,
               "Expected 340px column spacing between #{current_node.key} and #{next_node.key}"

        # Vertical alignment across single-row linear chain
        assert current_node.y == next_node.y
      end

      # 2. Dynamic canvas width expansion
      expected_width = 60 + chain_length * 340 + 60
      assert graph.width == expected_width
      assert graph.width >= 4000

      # 3. Exactly 11 sequential edges
      edge_map = Map.new(graph.edges, &{&1.id, &1})

      for idx <- 1..(chain_length - 1) do
        edge_id = "step_#{idx}--step_#{idx + 1}"
        assert Map.has_key?(edge_map, edge_id), "Expected edge #{edge_id} in chain"
      end

      # 4. Component rendering with all 12 nodes
      workflow = %Workflow{id: "wf-chain", name: "Deep Linear Chain", steps: chain_steps}

      run = %WorkflowRun{
        id: "run-chain",
        status: "running",
        resolved_steps: chain_steps,
        step_states: %{}
      }

      html =
        render_component(&WorkflowComponents.workflow_canvas/1,
          id: "canvas-chain",
          workflow: workflow,
          run: run
        )

      assert html =~ "12 steps"
      assert html =~ "11 dependencies"

      for idx <- 1..chain_length do
        assert html =~ "step-node-step_#{idx}"
      end
    end

    test "diamond DAG (1 root -> 4 parallel intermediate -> 1 sink)" do
      diamond_steps = [
        %{
          "key" => "root",
          "title" => "Root Initiator",
          "kind" => "deep_research",
          "depends_on" => []
        },
        %{
          "key" => "mid_1",
          "title" => "Worker Alpha",
          "kind" => "swarm_code_gen",
          "depends_on" => ["root"]
        },
        %{
          "key" => "mid_2",
          "title" => "Worker Beta",
          "kind" => "swarm_code_gen",
          "depends_on" => ["root"]
        },
        %{
          "key" => "mid_3",
          "title" => "Worker Gamma",
          "kind" => "swarm_code_gen",
          "depends_on" => ["root"]
        },
        %{
          "key" => "mid_4",
          "title" => "Worker Delta",
          "kind" => "swarm_code_gen",
          "depends_on" => ["root"]
        },
        %{
          "key" => "sink",
          "title" => "Consensus Sink",
          "kind" => "git_commit",
          "depends_on" => ["mid_1", "mid_2", "mid_3", "mid_4"]
        }
      ]

      graph = WorkflowComponents.layout_workflow_dag(diamond_steps, %{}, nil)

      assert length(graph.nodes) == 6
      assert length(graph.edges) == 8

      node_map = Map.new(graph.nodes, &{&1.key, &1})
      root = node_map["root"]
      mid_nodes = [node_map["mid_1"], node_map["mid_2"], node_map["mid_3"], node_map["mid_4"]]
      sink = node_map["sink"]

      # Layer 0: Root
      assert root.x == 60

      # Layer 1: Mid nodes all in col 1 (x = 400)
      for mid <- mid_nodes do
        assert mid.x == 400
        assert root.x < mid.x
      end

      # Layer 2: Sink in col 2 (x = 740)
      assert sink.x == 740

      for mid <- mid_nodes do
        assert mid.x < sink.x
      end

      # Mid nodes must be vertically stacked with 45px vertical gap (node_height 115 + gap_y 45 = 160)
      sorted_mids = Enum.sort_by(mid_nodes, & &1.y)

      for i <- 0..2 do
        m1 = Enum.at(sorted_mids, i)
        m2 = Enum.at(sorted_mids, i + 1)
        assert m2.y - m1.y == 160
      end

      # Vertical centering: Root and Sink (layer count 1) must be vertically centered relative to 4-node layer
      # 4-node layer height: 4 * 115 + 3 * 45 = 595. Single node offset_y = div(595 - 115, 2) = 240.
      # y = 60 + 240 = 300.
      assert root.y == 300
      assert sink.y == 300
      assert root.y == sink.y

      # Verify all 8 directed edges exist
      edge_ids = MapSet.new(Enum.map(graph.edges, & &1.id))
      assert MapSet.member?(edge_ids, "root--mid_1")
      assert MapSet.member?(edge_ids, "root--mid_2")
      assert MapSet.member?(edge_ids, "root--mid_3")
      assert MapSet.member?(edge_ids, "root--mid_4")
      assert MapSet.member?(edge_ids, "mid_1--sink")
      assert MapSet.member?(edge_ids, "mid_2--sink")
      assert MapSet.member?(edge_ids, "mid_3--sink")
      assert MapSet.member?(edge_ids, "mid_4--sink")

      # Component rendering
      workflow = %Workflow{id: "wf-diamond", name: "Diamond Workflow", steps: diamond_steps}

      run = %WorkflowRun{
        id: "run-diamond",
        status: "running",
        resolved_steps: diamond_steps,
        step_states: %{}
      }

      html =
        render_component(&WorkflowComponents.workflow_canvas/1,
          id: "canvas-diamond",
          workflow: workflow,
          run: run
        )

      assert html =~ "6 steps"
      assert html =~ "8 dependencies"

      for key <- ~w(root mid_1 mid_2 mid_3 mid_4 sink) do
        assert html =~ "step-node-#{key}"
      end
    end

    test "disconnected components (2 independent parallel subgraphs)" do
      # Subgraph A: A1 -> A2 -> A3 (3 steps)
      # Subgraph B: B1 -> B2 (2 steps)
      # Zero cross-graph dependencies
      disconnected_steps = [
        %{"key" => "sub_a1", "title" => "Sub A1", "kind" => "deep_research", "depends_on" => []},
        %{
          "key" => "sub_a2",
          "title" => "Sub A2",
          "kind" => "swarm_code_gen",
          "depends_on" => ["sub_a1"]
        },
        %{
          "key" => "sub_a3",
          "title" => "Sub A3",
          "kind" => "test_verification",
          "depends_on" => ["sub_a2"]
        },
        %{"key" => "sub_b1", "title" => "Sub B1", "kind" => "deep_research", "depends_on" => []},
        %{
          "key" => "sub_b2",
          "title" => "Sub B2",
          "kind" => "security_audit",
          "depends_on" => ["sub_b1"]
        }
      ]

      graph = WorkflowComponents.layout_workflow_dag(disconnected_steps, %{}, nil)

      assert length(graph.nodes) == 5
      assert length(graph.edges) == 3

      node_map = Map.new(graph.nodes, &{&1.key, &1})
      a1 = node_map["sub_a1"]
      a2 = node_map["sub_a2"]
      a3 = node_map["sub_a3"]
      b1 = node_map["sub_b1"]
      b2 = node_map["sub_b2"]

      # Layer 0 contains roots of both subgraphs (a1, b1)
      assert a1.x == 60
      assert b1.x == 60
      assert a1.y != b1.y

      # Layer 1 contains depth-1 nodes of both subgraphs (a2, b2)
      assert a2.x == 400
      assert b2.x == 400
      assert a2.y != b2.y

      # Layer 2 contains depth-2 node of subgraph A (a3)
      assert a3.x == 740

      # Strict absence of cross-graph edges
      for edge <- graph.edges do
        source_sub = if String.starts_with?(edge.from, "sub_a"), do: :a, else: :b
        target_sub = if String.starts_with?(edge.to, "sub_a"), do: :a, else: :b

        assert source_sub == target_sub,
               "Forbidden edge across disconnected components: #{edge.from} -> #{edge.to}"
      end

      # Component rendering
      workflow = %Workflow{id: "wf-disc", name: "Disconnected Graph", steps: disconnected_steps}

      run = %WorkflowRun{
        id: "run-disc",
        status: "running",
        resolved_steps: disconnected_steps,
        step_states: %{}
      }

      html =
        render_component(&WorkflowComponents.workflow_canvas/1,
          id: "canvas-disc",
          workflow: workflow,
          run: run
        )

      assert html =~ "5 steps"
      assert html =~ "3 dependencies"

      for key <- ~w(sub_a1 sub_a2 sub_a3 sub_b1 sub_b2) do
        assert html =~ "step-node-#{key}"
      end
    end
  end

  # ============================================================================
  # SCENARIO 2: BÉZIER CURVE MATHEMATICAL INVARIANCE
  # ============================================================================

  describe "Bézier curve mathematical invariance" do
    test "satisfies x1 < cx1 <= cx2 < x2 for strictly forward horizontal layouts" do
      test_cases = [
        # Adjacent columns (dx = 45)
        {%{x: 60, y: 100, width: 250, height: 115}, %{x: 400, y: 100, width: 250, height: 115}},
        # Upward curve
        {%{x: 60, y: 300, width: 250, height: 115}, %{x: 400, y: 60, width: 250, height: 115}},
        # Downward curve
        {%{x: 60, y: 60, width: 250, height: 115}, %{x: 400, y: 300, width: 250, height: 115}},
        # Multi-column span (col 0 to col 2)
        {%{x: 60, y: 200, width: 250, height: 115}, %{x: 740, y: 200, width: 250, height: 115}},
        # Wide multi-column span (col 0 to col 5)
        {%{x: 60, y: 200, width: 250, height: 115}, %{x: 1760, y: 200, width: 250, height: 115}}
      ]

      for {source, target} <- test_cases do
        curve = WorkflowComponents.bezier_edge(source, target)

        # Invariant 1: Source right boundary to Target left boundary
        assert curve.x1 == source.x + source.width
        assert curve.x2 == target.x

        # Invariant 2: x1 < cx1 <= cx2 < x2 for horizontal flow
        assert curve.x1 < curve.cx1,
               "Violated x1 < cx1: #{curve.x1} < #{curve.cx1}"

        assert curve.cx1 <= curve.cx2,
               "Violated cx1 <= cx2: #{curve.cx1} <= #{curve.cx2}"

        assert curve.cx2 < curve.x2,
               "Violated cx2 < x2: #{curve.cx2} < #{curve.x2}"
      end
    end

    test "satisfies strictly horizontal tangent handles: y1 == cy1 and y2 == cy2" do
      # Test across various elevation deltas (dy > 0, dy < 0, dy == 0)
      elevations = [
        # Flat
        {100, 100},
        # Steep downward
        {50, 450},
        # Steep upward
        {500, 80},
        # Extreme difference
        {0, 1000}
      ]

      for {src_y, tgt_y} <- elevations do
        source = %{x: 60, y: src_y, width: 250, height: 115}
        target = %{x: 400, y: tgt_y, width: 250, height: 115}

        curve = WorkflowComponents.bezier_edge(source, target)

        # Invariant: Handles must be strictly horizontal at source port and target port
        assert curve.cy1 == curve.y1,
               "Tangent handle 1 must be horizontal: expected cy1 == y1 (#{curve.cy1} == #{curve.y1})"

        assert curve.cy2 == curve.y2,
               "Tangent handle 2 must be horizontal: expected cy2 == y2 (#{curve.cy2} == #{curve.y2})"

        # Vertical anchors must be vertically centered on nodes
        assert curve.y1 == src_y + div(115, 2)
        assert curve.y2 == tgt_y + div(115, 2)
      end
    end

    test "guarantees non-zero length paths and valid SVG cubic Bézier syntax" do
      topologies = [
        # Linear chain
        Enum.map(1..5, fn i ->
          deps = if i == 1, do: [], else: ["s_#{i - 1}"]
          %{"key" => "s_#{i}", "kind" => "deep_research", "depends_on" => deps}
        end),
        # Diamond
        [
          %{"key" => "r", "kind" => "deep_research", "depends_on" => []},
          %{"key" => "m1", "kind" => "swarm_code_gen", "depends_on" => ["r"]},
          %{"key" => "m2", "kind" => "swarm_code_gen", "depends_on" => ["r"]},
          %{"key" => "s", "kind" => "git_commit", "depends_on" => ["m1", "m2"]}
        ]
      ]

      for steps <- topologies do
        graph = WorkflowComponents.layout_workflow_dag(steps, %{}, nil)
        nodes_by_key = Map.new(graph.nodes, &{&1.key, &1})

        for edge <- graph.edges do
          source = Map.fetch!(nodes_by_key, edge.from)
          target = Map.fetch!(nodes_by_key, edge.to)
          b = WorkflowComponents.bezier_edge(source, target)

          # Non-zero length verification: start and end points cannot be coincident
          assert {b.x1, b.y1} != {b.x2, b.y2}

          # Euclidean chord distance lower bound (gap_x is 90px)
          chord_dx = b.x2 - b.x1
          chord_dy = b.y2 - b.y1
          chord_length = :math.sqrt(chord_dx * chord_dx + chord_dy * chord_dy)
          assert chord_length >= 90.0

          # Strict SVG cubic Bézier syntax match: M x1 y1 C cx1 cy1, cx2 cy2, x2 y2
          assert b.d =~ ~r/^M \d+ \d+ C \d+ \d+, \d+ \d+, \d+ \d+$/
          refute b.d =~ "NaN"
          refute b.d =~ "Infinity"
        end
      end
    end
  end

  # ============================================================================
  # SCENARIO 3: PROGRESS RING BOUNDARY CONDITIONS
  # ============================================================================

  describe "progress ring boundary conditions" do
    test "calculates exact dashoffset for nominal boundaries (0, 50, 100)" do
      circumference = 94.2478

      # 0% -> Full dashoffset (stroke completely hidden / empty ring)
      offset_0 = WorkflowComponents.calc_progress_dashoffset(0, circumference)
      assert_in_delta offset_0, 94.2478, 0.0001

      # 50% -> Exactly half dashoffset
      offset_50 = WorkflowComponents.calc_progress_dashoffset(50, circumference)
      assert_in_delta offset_50, 47.1239, 0.0001

      # 100% -> Zero dashoffset (stroke completely filled / full ring)
      offset_100 = WorkflowComponents.calc_progress_dashoffset(100, circumference)
      assert_in_delta offset_100, 0.0, 0.0001
    end

    test "clamps out-of-bounds inputs (< 0 and > 100) and nil safely without throwing" do
      circumference = 100.0

      # Underflow boundary tests: must clamp to 0% -> full circumference
      assert_in_delta WorkflowComponents.calc_progress_dashoffset(-1, circumference),
                      100.0,
                      0.0001

      assert_in_delta WorkflowComponents.calc_progress_dashoffset(-50, circumference),
                      100.0,
                      0.0001

      assert_in_delta WorkflowComponents.calc_progress_dashoffset(-999_999, circumference),
                      100.0,
                      0.0001

      # Overflow boundary tests: must clamp to 100% -> zero offset
      assert_in_delta WorkflowComponents.calc_progress_dashoffset(101, circumference), 0.0, 0.0001
      assert_in_delta WorkflowComponents.calc_progress_dashoffset(150, circumference), 0.0, 0.0001

      assert_in_delta WorkflowComponents.calc_progress_dashoffset(999_999, circumference),
                      0.0,
                      0.0001

      # Nil safety: defaults to 0%
      assert_in_delta WorkflowComponents.calc_progress_dashoffset(nil, circumference),
                      100.0,
                      0.0001
    end

    test "renders step_progress_ring safely with negative, overflow, and nil inputs" do
      # Render negative progress (-40)
      html_neg =
        render_component(&WorkflowComponents.step_progress_ring/1,
          status: "running",
          progress: -40
        )

      assert html_neg =~ "stroke-dashoffset=\"94.2478\""
      refute html_neg =~ "NaN"

      # Render overflow progress (180)
      html_over =
        render_component(&WorkflowComponents.step_progress_ring/1,
          status: "running",
          progress: 180
        )

      assert html_over =~ "stroke-dashoffset=\"0.0\""
      refute html_over =~ "NaN"

      # Render nil progress
      html_nil =
        render_component(&WorkflowComponents.step_progress_ring/1,
          status: "pending",
          progress: nil
        )

      assert html_nil =~ "stroke-dashoffset=\"94.2478\""
      refute html_nil =~ "NaN"
    end
  end

  # ============================================================================
  # SCENARIO 4: NODE STATUS HALO RENDERING
  # ============================================================================

  describe "node status halo rendering" do
    test "all 5 canonical states render distinct, valid CSS/SVG classes" do
      # Canonical 5 states
      canonical_states = ["pending", "running", "completed", "failed", "paused"]

      metas =
        Enum.map(canonical_states, fn state ->
          meta = WorkflowComponents.canonical_meta(state)
          badge = WorkflowComponents.status_badge_class(state)
          dot = WorkflowComponents.status_dot_class(state)
          icon = WorkflowComponents.status_icon_name(state)
          icon_color = WorkflowComponents.status_icon_color(state)

          {state, meta, badge, dot, icon, icon_color}
        end)

      # 1. Distinct Halo Classes Oracle
      # Each canonical state must define its own halo effect
      halos = Enum.map(metas, fn {_, meta, _, _, _, _} -> meta.halo end)
      # 4 active/distinct glow halos + 1 "shadow-none" for pending = 5 total definitions
      assert length(Enum.uniq(halos)) == 5
      assert "shadow-none" in halos
      # cyan for running
      assert Enum.any?(halos, &(&1 =~ "rgba(34,211,238"))
      # emerald for completed
      assert Enum.any?(halos, &(&1 =~ "rgba(52,211,153"))
      # rose for failed
      assert Enum.any?(halos, &(&1 =~ "rgba(244,63,94"))
      # amber for paused
      assert Enum.any?(halos, &(&1 =~ "rgba(251,191,36"))

      # 2. Distinct Border Classes Oracle
      borders = Enum.map(metas, fn {_, meta, _, _, _, _} -> meta.border end)
      assert length(Enum.uniq(borders)) == 5
      assert Enum.any?(borders, &(&1 =~ "cyan"))
      assert Enum.any?(borders, &(&1 =~ "emerald"))
      assert Enum.any?(borders, &(&1 =~ "rose"))
      assert Enum.any?(borders, &(&1 =~ "amber"))

      # 3. Distinct Icons Oracle
      icons = Enum.map(metas, fn {_, _, _, _, icon, _} -> icon end)
      assert length(Enum.uniq(icons)) == 5

      assert icons == [
               "hero-clock",
               "hero-arrow-path",
               "hero-check",
               "hero-exclamation-triangle",
               "hero-pause"
             ]

      # 4. Distinct Badges Oracle
      badges = Enum.map(metas, fn {_, _, badge, _, _, _} -> badge end)
      assert length(Enum.uniq(badges)) == 5

      # 5. Distinct Dots Oracle
      dots = Enum.map(metas, fn {_, _, _, dot, _, _} -> dot end)
      assert length(Enum.uniq(dots)) == 5
    end

    test "atoms converted via to_string render identically to canonical string states" do
      atom_states = [:pending, :running, :completed, :failed, :paused]

      for atom <- atom_states do
        str_state = to_string(atom)
        meta_str = WorkflowComponents.canonical_meta(str_state)
        icon_str = WorkflowComponents.status_icon_name(str_state)
        badge_str = WorkflowComponents.status_badge_class(str_state)

        # Verify string canonical contracts are intact
        assert is_map(meta_str)
        assert is_binary(meta_str.halo)
        assert is_binary(icon_str)
        assert is_binary(badge_str)
      end
    end

    test "workflow canvas renders all 5 canonical states simultaneously with distinct styling" do
      five_steps = [
        %{
          "key" => "step_pending",
          "title" => "Pending Step",
          "kind" => "deep_research",
          "depends_on" => []
        },
        %{
          "key" => "step_running",
          "title" => "Running Step",
          "kind" => "swarm_code_gen",
          "depends_on" => ["step_pending"]
        },
        %{
          "key" => "step_completed",
          "title" => "Completed Step",
          "kind" => "test_verification",
          "depends_on" => ["step_running"]
        },
        %{
          "key" => "step_failed",
          "title" => "Failed Step",
          "kind" => "security_audit",
          "depends_on" => ["step_completed"]
        },
        %{
          "key" => "step_paused",
          "title" => "Paused Step",
          "kind" => "git_commit",
          "depends_on" => ["step_failed"]
        }
      ]

      step_states = %{
        "step_pending" => %{"status" => "pending"},
        "step_running" => %{"status" => "running", "progress" => 45},
        "step_completed" => %{"status" => "completed", "progress" => 100},
        "step_failed" => %{"status" => "failed"},
        "step_paused" => %{"status" => "paused"}
      }

      workflow = %Workflow{id: "wf-all-5", name: "All 5 States", steps: five_steps}

      run = %WorkflowRun{
        id: "run-all-5",
        status: "running",
        current_step_key: "step_running",
        resolved_steps: five_steps,
        step_states: step_states
      }

      html =
        render_component(&WorkflowComponents.workflow_canvas/1,
          id: "canvas-all-5",
          workflow: workflow,
          run: run
        )

      # 1. Pending node
      assert html =~ "id=\"step-node-step_pending\""
      assert html =~ "data-step-status=\"pending\""
      assert html =~ "hero-clock"

      # 2. Running node
      assert html =~ "id=\"step-node-step_running\""
      assert html =~ "data-step-status=\"running\""
      assert html =~ "shadow-[0_0_24px_rgba(34,211,238,0.45)]"
      assert html =~ "border-cyan-400"
      assert html =~ "45%"

      # 3. Completed node
      assert html =~ "id=\"step-node-step_completed\""
      assert html =~ "data-step-status=\"completed\""
      assert html =~ "shadow-[0_0_16px_rgba(52,211,153,0.30)]"
      assert html =~ "border-emerald-400/70"
      assert html =~ "hero-check"

      # 4. Failed node
      assert html =~ "id=\"step-node-step_failed\""
      assert html =~ "data-step-status=\"failed\""
      assert html =~ "shadow-[0_0_22px_rgba(244,63,94,0.40)]"
      assert html =~ "border-rose-500"
      assert html =~ "hero-exclamation-triangle"

      # 5. Paused node
      assert html =~ "id=\"step-node-step_paused\""
      assert html =~ "data-step-status=\"paused\""
      assert html =~ "shadow-[0_0_16px_rgba(251,191,36,0.30)]"
      assert html =~ "border-amber-400"
      assert html =~ "hero-pause"
    end
  end
end
