defmodule IexCode.Engine.OperationProjectionTest do
  use ExUnit.Case, async: true

  alias IexCode.Engine.OperationProjection
  alias IexCode.OperationProjectionFixture

  test "exceptions project safely without requiring Enumerable" do
    projected = OperationProjection.text(%RuntimeError{message: "bounded runtime failure"})

    assert projected =~ "bounded runtime failure"
    assert byte_size(projected) <= OperationProjection.max_text_bytes()
  end

  test "custom non-Enumerable structs retain bounded artifact references" do
    artifact_id = Ecto.UUID.generate()

    projected =
      OperationProjection.text(%OperationProjectionFixture{
        artifact_id: artifact_id,
        nested: %{"artifact_id" => "nested-artifact"},
        message: String.duplicate("m", 100_000)
      })

    [prefix | _rest] = String.split(projected, "\n", parts: 2)
    assert prefix =~ artifact_id
    assert prefix =~ "nested-artifact"
    assert byte_size(projected) <= OperationProjection.max_text_bytes()
  end

  test "artifact collection stops at the fixed cap before descending" do
    direct_ids = Enum.map(1..10_000, &"direct-artifact-#{&1}")

    projected =
      OperationProjection.text(%{
        "artifact_ids" => direct_ids,
        "nested" => %{"artifact_id" => "nested-artifact-must-not-enter-prefix"},
        "payload" => String.duplicate("x", 100_000)
      })

    [prefix | _rest] = String.split(projected, "\n", parts: 2)
    assert prefix == "Artifacts: " <> Enum.join(Enum.take(direct_ids, 16), ", ")
  end

  test "wide list traversal is bounded before visiting later children" do
    value =
      List.duplicate(%{"ordinary" => true}, 256) ++
        [%{"artifact_id" => "artifact-beyond-wide-bound"}]

    refute OperationProjection.text(value) |> String.starts_with?("Artifacts:")
  end

  test "truncated params retain at most sixteen unique artifact references" do
    ids = Enum.map(1..10_000, &"artifact-#{&1}")

    assert %{"_truncated" => true, "artifact_ids" => artifact_ids} =
             OperationProjection.params(%{
               "artifact_ids" => ids,
               "payload_a" => String.duplicate("p", 100_000),
               "payload_b" => String.duplicate("q", 100_000)
             })

    assert artifact_ids == Enum.take(ids, 16)
  end

  test "params enforce one aggregate traversal budget across nested collections" do
    value =
      for outer <- 1..256 do
        {"branch-#{outer}", Enum.map(1..256, &%{"leaf-#{&1}" => &1})}
      end
      |> Map.new()

    assert %{
             "_truncated" => true,
             "artifact_ids" => [],
             "preview" => preview
           } = OperationProjection.params(value)

    assert is_binary(preview)
    assert byte_size(preview) <= 16 * 1_024
  end

  test "oversized and invalid map keys cannot escape bounded valid UTF-8 projection" do
    invalid_key = <<255>> <> String.duplicate("k", 10_000)

    projected = OperationProjection.params(%{invalid_key => "value"})
    assert {:ok, encoded} = Jason.encode(projected)
    assert byte_size(encoded) <= OperationProjection.max_params_bytes()
    assert String.valid?(encoded)
  end
end
