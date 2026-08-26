defmodule IexCode.Runs.ExecutionEngineTest do
  use ExUnit.Case, async: true

  alias IexCode.Runs.ExecutionEngine
  alias IexCode.Runs.ExecutionEngines.DagV1

  test "legacy_v1 validates structure without scheduling dependency metadata" do
    steps = [
      %{key: "prepare", kind: "prepare", depends_on: []},
      %{key: "execute", kind: "execute", depends_on: ["prepare"]}
    ]

    assert :ok = ExecutionEngine.validate_manifest(%{execution_engine: "legacy_v1"}, steps)
  end

  test "legacy_v1 rejects duplicate identities" do
    steps = [%{key: "same", kind: "prepare"}, %{key: "same", kind: "execute"}]

    assert {:error, :duplicate_step_key} =
             ExecutionEngine.validate_manifest(%{execution_engine: "legacy_v1"}, steps)
  end

  test "dag_v1 rejects empty graphs and validates its closed canonical handlers" do
    assert {:error, :empty_dag_manifest} =
             ExecutionEngine.validate_manifest(%{execution_engine: "dag_v1"}, [])

    assert :ok =
             ExecutionEngine.validate_manifest(%{execution_engine: "dag_v1"}, [
               %{key: "inventory", kind: "project_inventory", title: "Inventory"}
             ])
  end

  test "unknown engines never fall back to legacy" do
    assert {:error, {:unknown_execution_engine, "invented"}} =
             ExecutionEngine.validate_manifest(%{execution_engine: "invented"}, [])
  end

  test "descriptors truthfully expose availability" do
    assert %{id: "legacy_v1", available: true} in ExecutionEngine.descriptors()
    assert %{id: "dag_v1", available: true} in ExecutionEngine.descriptors()
    assert ExecutionEngine.available_ids() == ["dag_v1", "legacy_v1"]
  end

  test "dag adapter canonicalizes lifecycle and handler authority" do
    caller_steps = [
      %{
        "key" => "read",
        "kind" => "read_file",
        "title" => "Read",
        "params" => %{"path" => "README.md"}
      },
      %{
        "key" => "join",
        "kind" => "aggregate",
        "title" => "Join",
        "depends_on" => ["read"]
      }
    ]

    assert {:ok, %{steps: [join, read], manifest_hash: hash}} =
             DagV1.prepare_manifest(%{}, Enum.reverse(caller_steps))

    assert join.key == "join"
    assert join.status == "pending"
    assert join.effect_class == "pure"
    assert join.replay_policy == "safe"
    assert join.resource_spec == %{"contract" => "project_read_v1"}
    assert join.handler_version == 1
    assert join.timeout_ms == 30_000
    assert read.status == "ready"
    assert byte_size(hash) == 64

    assert :ok = ExecutionEngine.validate_manifest(%{execution_engine: "dag_v1"}, caller_steps)
  end
end
