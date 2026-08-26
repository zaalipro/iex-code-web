defmodule IexCode.Runs.DagManifestTest do
  use ExUnit.Case, async: true

  alias IexCode.Runs.DagManifest

  defp graph do
    [
      %{"key" => "inventory", "kind" => "project_inventory", "title" => "Inventory"},
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
        "depends_on" => ["read", "inventory"]
      }
    ]
  end

  test "normalizes deterministically and hashes handler contracts" do
    assert {:ok, normalized} = DagManifest.normalize(Enum.reverse(graph()))
    assert Enum.map(normalized, & &1.key) == ["inventory", "join", "read"]
    assert Enum.find(normalized, &(&1.key == "join")).depends_on == ["inventory", "read"]

    assert {:ok, first} = DagManifest.hash(graph())
    assert {:ok, second} = DagManifest.hash(Enum.reverse(graph()))
    assert first == second
    assert byte_size(first) == 64
  end

  test "rejects ambiguous aliases, forged lifecycle fields and structs" do
    [first | rest] = graph()

    assert {:error, {:invalid_dag_step, 0, {:duplicate_field_aliases, ["key"]}}} =
             DagManifest.normalize([Map.put(first, :key, "other") | rest])

    assert {:error, {:invalid_dag_step, 0, {:unknown_fields, _}}} =
             DagManifest.normalize([Map.put(first, "status", "completed") | rest])

    assert {:error, {:invalid_dag_step, 0, :not_a_plain_map}} =
             DagManifest.normalize([%URI{scheme: "https"}])
  end

  test "rejects missing, self, duplicate and cyclic dependencies" do
    assert {:error, {:missing_dependencies, "join", ["missing"]}} =
             graph()
             |> List.update_at(2, &Map.put(&1, "depends_on", ["missing"]))
             |> DagManifest.normalize()

    assert {:error, {:self_dependency, "join"}} =
             graph()
             |> List.update_at(2, &Map.put(&1, "depends_on", ["join"]))
             |> DagManifest.normalize()

    assert {:error, {:invalid_dag_step, 2, :duplicate_dependencies}} =
             graph()
             |> List.update_at(2, &Map.put(&1, "depends_on", ["read", "read"]))
             |> DagManifest.normalize()

    cyclic = [
      %{"key" => "a", "kind" => "aggregate", "title" => "A", "depends_on" => ["b"]},
      %{"key" => "b", "kind" => "aggregate", "title" => "B", "depends_on" => ["a"]}
    ]

    assert {:error, :cyclic_dependencies} = DagManifest.normalize(cyclic)
  end

  test "rejects unsupported handlers and bounded JSON secrets" do
    [first | rest] = graph()

    assert {:error, {:invalid_dag_step, 0, {:unsupported_kind, "Elixir.System"}}} =
             DagManifest.normalize([Map.put(first, "kind", "Elixir.System") | rest])

    secret = put_in(Enum.at(graph(), 1)["params"], %{"nested" => [%{"access_token" => "x"}]})

    assert {:error, {:invalid_dag_step, 1, :secret_payload_forbidden}} =
             DagManifest.normalize(List.replace_at(graph(), 1, secret))
  end

  test "enforces graph depth and edge bounds" do
    deep =
      Enum.map(1..33, fn index ->
        if index == 1 do
          %{"key" => "n1", "kind" => "project_inventory", "title" => "Node 1"}
        else
          %{
            "key" => "n#{index}",
            "kind" => "aggregate",
            "title" => "Node #{index}",
            "depends_on" => ["n#{index - 1}"]
          }
        end
      end)

    assert {:error, {:graph_too_deep, 32}} = DagManifest.normalize(deep)

    oversized =
      Enum.map(1..129, fn index ->
        %{"key" => "n#{index}", "kind" => "project_inventory", "title" => "Node #{index}"}
      end)

    assert {:error, {:manifest_too_large, 128}} = DagManifest.normalize(oversized)

    roots =
      Enum.map(1..32, fn index ->
        %{"key" => "r#{index}", "kind" => "project_inventory", "title" => "Root #{index}"}
      end)

    root_keys = Enum.map(roots, & &1["key"])

    joins =
      Enum.map(1..16, fn index ->
        %{
          "key" => "j#{index}",
          "kind" => "aggregate",
          "title" => "Join #{index}",
          "depends_on" => root_keys
        }
      end)

    extra = %{
      "key" => "extra",
      "kind" => "aggregate",
      "title" => "Extra",
      "depends_on" => ["r1"]
    }

    assert {:error, {:manifest_has_too_many_edges, 512}} =
             DagManifest.normalize(roots ++ joins ++ [extra])
  end

  test "enforces encoded size, JSON depth and collection limits" do
    base = %{"key" => "inventory", "kind" => "project_inventory", "title" => "Inventory"}

    assert {:error, {:invalid_dag_step, 0, {:payload_too_large, 64_000}}} =
             DagManifest.normalize([
               Map.put(base, "params", %{"blob" => String.duplicate("x", 64_001)})
             ])

    deeply_nested = Enum.reduce(1..13, "leaf", fn index, nested -> %{"n#{index}" => nested} end)

    assert {:error, {:invalid_dag_step, 0, {:json_depth_exceeded, 12}}} =
             DagManifest.normalize([Map.put(base, "params", %{"nested" => deeply_nested})])

    assert {:error, {:invalid_dag_step, 0, {:json_collection_too_large, 512}}} =
             DagManifest.normalize([Map.put(base, "params", %{"items" => Enum.to_list(1..513)})])
  end
end
