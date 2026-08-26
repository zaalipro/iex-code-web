defmodule IexCode.Research.ResultTest do
  use ExUnit.Case, async: true

  alias IexCode.Research.Result

  test "normalizes provider identity and accepts atom or string keyed data" do
    result =
      Result.new(:brave, %{
        "title" => "  Useful result ",
        "url" => "https://example.com/post",
        "snippet" => " summary ",
        "score" => 0.9
      })

    assert %Result{
             provider: "brave",
             title: "Useful result",
             url: "https://example.com/post",
             snippet: "summary",
             score: 0.9
           } = result
  end

  test "rejects results without the minimum citeable fields" do
    assert is_nil(Result.new(:bing, %{title: "", url: "https://example.com"}))
    assert is_nil(Result.new(:bing, %{title: "A", url: nil}))
  end

  test "merges normalized provenance without discarding primary provider metadata" do
    primary =
      Result.new(:brave, %{
        title: "Primary",
        url: "https://example.com/article/",
        snippet: "first",
        metadata: %{"language" => "en"}
      })

    duplicate =
      Result.new(:exa, %{
        title: "Alternate title",
        url: "https://example.com/article",
        snippet: "second",
        score: 0.8
      })

    merged = Result.merge_provenance(primary, duplicate)

    assert merged.provider == "brave"
    assert merged.metadata["language"] == "en"

    assert Enum.map(Result.provenance(merged), & &1["provider"]) == ["brave", "exa"]
    assert Enum.at(Result.provenance(merged), 1)["score"] == 0.8
  end
end
