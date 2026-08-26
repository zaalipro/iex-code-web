defmodule IexCode.Research.LevelPolicyTest do
  use ExUnit.Case, async: true

  alias IexCode.Research.LevelPolicy

  test "exposes the exact lead, round and asynchronous subagent contract" do
    assert {:ok, low} = LevelPolicy.fetch(:low)
    assert {:ok, medium} = LevelPolicy.fetch("medium")
    assert {:ok, high} = LevelPolicy.fetch("high")
    assert {:ok, ultra} = LevelPolicy.fetch("ultra")

    assert {low.multistep_rounds, low.async_subagents, low.lead_per_step} == {1, 2, 1}
    assert {medium.multistep_rounds, medium.async_subagents, medium.lead_per_step} == {2, 3, 1}
    assert {high.multistep_rounds, high.async_subagents, high.lead_per_step} == {3, 4, 1}
    assert {ultra.multistep_rounds, ultra.async_subagents, ultra.lead_per_step} == {4, 10, 1}

    assert :ok = LevelPolicy.validate_durable(LevelPolicy.durable(ultra))

    assert {:error, :research_level_policy_drift} =
             LevelPolicy.validate_durable(%{LevelPolicy.durable(ultra) | "async_subagents" => 9})

    assert {:error, :invalid_research_level} = LevelPolicy.fetch("deep")
  end

  test "ultra manifests allocate enough deterministic query work for all ten subagents" do
    assert {:ok, nodes} =
             IexCode.Research.DagAdapter.build("Research",
               level: "ultra",
               ranked_providers: ["duckduckgo"]
             )

    assert Enum.all?(Enum.filter(nodes, &(&1.kind == "research_plan")), fn node ->
             node.params["max_queries"] >= 10
           end)

    assert Enum.all?(Enum.filter(nodes, &(&1.kind == "research_ranked_search")), fn node ->
             node.params["max_search_calls"] >= 10
           end)
  end
end
