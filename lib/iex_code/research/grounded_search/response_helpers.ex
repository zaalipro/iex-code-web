defmodule IexCode.Research.GroundedSearch.ResponseHelpers do
  @moduledoc false

  alias IexCode.Research.GroundedSearch.Normalizer, as: N

  def answer_and_citations(
        block_groups,
        text_type,
        annotation_key \\ :annotations,
        index_unit \\ :characters
      ) do
    block_groups
    |> Enum.flat_map(&N.list/1)
    |> Enum.filter(fn block ->
      N.value(block, :type) == text_type and
        is_binary(N.value(block, :text)) and N.value(block, :text) != ""
    end)
    |> Enum.reduce({[], [], 0}, fn block, {texts, citations, offset} ->
      text = block |> N.value(:text) |> normalize_text()
      separator = if texts == [], do: 0, else: 1
      base = offset + separator

      block_citations =
        block
        |> N.value(annotation_key)
        |> N.list()
        |> Enum.flat_map(&normalize_annotation(&1, base, index_unit))

      {[text | texts], citations ++ block_citations, base + text_size(text, index_unit)}
    end)
    |> then(fn {texts, citations, _offset} ->
      {texts |> Enum.reverse() |> Enum.join("\n"), citations}
    end)
  end

  def url_citation(row, base \\ 0, index_unit \\ :characters) do
    if N.value(row, :type) in ["url_citation", "web_search_result_location"] do
      %{
        url: N.value(row, :url),
        title: N.value(row, :title),
        start_index: shifted(N.value(row, :start_index), base),
        end_index: shifted(N.value(row, :end_index), base),
        cited_text: N.value(row, :cited_text),
        metadata: %{"index_unit" => Atom.to_string(index_unit)}
      }
    end
  end

  def sum_usage(usages) do
    usages
    |> Enum.filter(&is_map/1)
    |> Enum.reduce(%{}, fn usage, acc -> merge_usage(acc, usage, 3) end)
  end

  defp normalize_annotation(row, base, index_unit) do
    case url_citation(row, base, index_unit) do
      nil -> []
      citation -> [citation]
    end
  end

  defp shifted(value, base) when is_integer(value) and value >= 0, do: value + base
  defp shifted(_value, _base), do: nil

  defp normalize_text(value) when is_binary(value), do: value
  defp normalize_text(_value), do: ""

  defp text_size(value, :bytes), do: byte_size(value)
  defp text_size(value, _index_unit), do: String.length(value)

  defp merge_usage(left, right, depth) when depth > 0 do
    Map.merge(left, right, fn _key, old, new ->
      cond do
        is_number(old) and is_number(new) -> old + new
        is_map(old) and is_map(new) -> merge_usage(old, new, depth - 1)
        true -> new
      end
    end)
  end
end
