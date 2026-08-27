defmodule IexCode.Engine.OperationProjection do
  @moduledoc "Bounded durable/UI projection of operation payloads."

  @max_text_bytes 64 * 1_024
  @max_params_bytes 64_000
  @edge_bytes 24 * 1_024
  @params_preview_bytes 16 * 1_024
  @max_collection_items 256
  @max_json_nodes 2_048
  @max_param_scalar_bytes @max_text_bytes
  @max_artifact_refs 16
  @max_artifact_nodes 2_048

  def max_text_bytes, do: @max_text_bytes
  def max_params_bytes, do: @max_params_bytes

  def text(value) when is_binary(value), do: bound_text(String.replace_invalid(value))

  def text(value) do
    artifact_refs = artifact_refs(value)

    rendered =
      inspect(value,
        limit: 512,
        printable_limit: @max_text_bytes,
        pretty: false,
        width: 120
      )

    prefix =
      case artifact_refs do
        [] -> ""
        refs -> "Artifacts: #{Enum.join(refs, ", ")}\n"
      end

    bound_text(prefix <> rendered)
  end

  def params(value) do
    {normalized, _nodes_left, traversal_truncated?} =
      json_value(value, 0, @max_json_nodes)

    case {traversal_truncated?, Jason.encode(normalized)} do
      {false, {:ok, encoded}} when byte_size(encoded) <= @max_params_bytes ->
        normalized

      _invalid_or_large ->
        %{
          "_truncated" => true,
          "preview" => value |> text() |> take_valid(@params_preview_bytes),
          "artifact_ids" => artifact_refs(value)
        }
    end
  end

  defp bound_text(value) when byte_size(value) <= @max_text_bytes, do: value

  defp bound_text(value) do
    omitted = byte_size(value) - @edge_bytes * 2

    String.replace_invalid(binary_part(value, 0, @edge_bytes)) <>
      "\n...[#{omitted} bytes omitted from operation projection]...\n" <>
      String.replace_invalid(binary_part(value, byte_size(value) - @edge_bytes, @edge_bytes))
  end

  defp json_value(_value, _depth, nodes_left) when nodes_left <= 0,
    do: {"[items truncated]", 0, true}

  defp json_value(_value, depth, nodes_left) when depth > 8,
    do: {"[depth truncated]", nodes_left - 1, true}

  defp json_value(nil, _depth, nodes_left), do: {nil, nodes_left - 1, false}

  defp json_value(value, _depth, nodes_left) when is_boolean(value) or is_number(value),
    do: {value, nodes_left - 1, false}

  defp json_value(value, _depth, nodes_left) when is_binary(value) do
    truncated? = byte_size(value) > @max_param_scalar_bytes
    {take_valid(value, @max_param_scalar_bytes), nodes_left - 1, truncated?}
  end

  defp json_value(values, depth, nodes_left) when is_list(values) do
    {items, nodes_left, truncated?} =
      Enum.reduce_while(values, {[], nodes_left - 1, false, 0}, fn nested,
                                                                   {items, remaining, truncated?,
                                                                    visited} ->
        cond do
          remaining <= 0 ->
            {:halt, {items, remaining, true, visited}}

          visited >= @max_collection_items ->
            {:halt, {items, remaining, true, visited}}

          true ->
            {item, remaining, item_truncated?} = json_value(nested, depth + 1, remaining)
            {:cont, {[item | items], remaining, truncated? or item_truncated?, visited + 1}}
        end
      end)
      |> then(fn {items, remaining, truncated?, _visited} ->
        {Enum.reverse(items), remaining, truncated?}
      end)

    {items, nodes_left, truncated?}
  end

  defp json_value(value, depth, nodes_left) when is_map(value) and not is_struct(value) do
    {entries, nodes_left, truncated?} =
      Enum.reduce_while(value, {[], nodes_left - 1, false, 0}, fn {key, nested},
                                                                  {entries, remaining, truncated?,
                                                                   visited} ->
        cond do
          remaining <= 0 ->
            {:halt, {entries, remaining, true, visited}}

          visited >= @max_collection_items ->
            {:halt, {entries, remaining, true, visited}}

          true ->
            {item, remaining, item_truncated?} = json_value(nested, depth + 1, remaining)
            key = bounded_key(key)

            {:cont,
             {[{key, item} | entries], remaining, truncated? or item_truncated?, visited + 1}}
        end
      end)
      |> then(fn {entries, remaining, truncated?, _visited} ->
        {entries, remaining, truncated?}
      end)

    {Map.new(entries), nodes_left, truncated?}
  end

  defp json_value(value, _depth, nodes_left),
    do: {value |> text() |> take_valid(@max_param_scalar_bytes), nodes_left - 1, true}

  defp artifact_refs(value) do
    state = %{refs: [], seen: MapSet.new(), count: 0, nodes_left: @max_artifact_nodes}
    state = collect_artifact_refs(value, state, 0)
    Enum.reverse(state.refs)
  end

  defp collect_artifact_refs(_value, state, depth)
       when depth > 8 or state.count >= @max_artifact_refs or state.nodes_left <= 0,
       do: state

  defp collect_artifact_refs(value, state, depth) when is_struct(value) do
    value
    |> Map.from_struct()
    |> collect_artifact_map(state, depth)
  end

  defp collect_artifact_refs(value, state, depth) when is_map(value) do
    collect_artifact_map(value, state, depth)
  end

  defp collect_artifact_refs(values, state, depth) when is_list(values) do
    state = %{state | nodes_left: state.nodes_left - 1}
    descend_list(values, state, depth)
  end

  defp collect_artifact_refs(_value, state, _depth),
    do: %{state | nodes_left: state.nodes_left - 1}

  defp collect_artifact_map(value, state, depth) do
    state = %{state | nodes_left: state.nodes_left - 1}

    state =
      Enum.reduce_while(
        [:artifact_id, "artifact_id", :artifact_ids, "artifact_ids"],
        state,
        fn key, state ->
          state = collect_direct_artifact_refs(Map.get(value, key), state)

          if artifact_refs_full?(state), do: {:halt, state}, else: {:cont, state}
        end
      )

    descend_map(value, state, depth)
  end

  defp collect_direct_artifact_refs(id, state) when is_binary(id),
    do: put_artifact_ref(state, id)

  defp collect_direct_artifact_refs(ids, state) when is_list(ids) do
    Enum.reduce_while(ids, {state, 0}, fn id, {state, visited} ->
      cond do
        artifact_refs_full?(state) ->
          {:halt, {state, visited}}

        visited >= @max_collection_items ->
          {:halt, {state, visited}}

        true ->
          {:cont, {collect_direct_artifact_refs(id, state), visited + 1}}
      end
    end)
    |> elem(0)
  end

  defp collect_direct_artifact_refs(_value, state), do: state

  defp descend_map(_value, state, _depth) when state.count >= @max_artifact_refs, do: state

  defp descend_map(value, state, depth) do
    Enum.reduce_while(value, {state, 0}, fn {_key, nested}, {state, visited} ->
      cond do
        artifact_refs_full?(state) ->
          {:halt, {state, visited}}

        visited >= @max_collection_items ->
          {:halt, {state, visited}}

        true ->
          {:cont, {collect_artifact_refs(nested, state, depth + 1), visited + 1}}
      end
    end)
    |> elem(0)
  end

  defp descend_list(_values, state, _depth) when state.count >= @max_artifact_refs, do: state

  defp descend_list(values, state, depth) do
    Enum.reduce_while(values, {state, 0}, fn nested, {state, visited} ->
      cond do
        artifact_refs_full?(state) ->
          {:halt, {state, visited}}

        visited >= @max_collection_items ->
          {:halt, {state, visited}}

        true ->
          {:cont, {collect_artifact_refs(nested, state, depth + 1), visited + 1}}
      end
    end)
    |> elem(0)
  end

  defp put_artifact_ref(state, id) do
    id = take_valid(id, 128)

    if MapSet.member?(state.seen, id) do
      state
    else
      %{
        state
        | refs: [id | state.refs],
          seen: MapSet.put(state.seen, id),
          count: state.count + 1
      }
    end
  end

  defp artifact_refs_full?(state),
    do: state.count >= @max_artifact_refs or state.nodes_left <= 0

  defp bounded_key(key) when is_binary(key), do: take_valid(key, 160)
  defp bounded_key(key) when is_atom(key), do: key |> Atom.to_string() |> take_valid(160)
  defp bounded_key(key) when is_integer(key), do: Integer.to_string(key)

  defp bounded_key(key) do
    key
    |> inspect(limit: 16, printable_limit: 160, pretty: false)
    |> take_valid(160)
  end

  defp take_valid(value, maximum) when byte_size(value) <= maximum,
    do: String.replace_invalid(value)

  defp take_valid(value, maximum),
    do: value |> binary_part(0, maximum) |> String.replace_invalid()
end
