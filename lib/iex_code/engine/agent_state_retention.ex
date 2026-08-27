defmodule IexCode.Engine.AgentStateRetention do
  @moduledoc false

  @default_inline_bytes 4_096
  @default_preview_bytes 512
  @default_history_items 8
  @default_history_bytes 32_768

  @hard_max_inline_bytes 32_768
  @hard_max_preview_bytes 4_096
  @hard_max_history_items 32
  @hard_max_history_bytes 262_144

  @summary_marker :iex_code_agent_result_summary

  @doc false
  def retain(value) do
    limits = limits()

    if external_size(value) <= limits.inline_bytes do
      value
    else
      summary(value, limits.preview_bytes)
    end
  end

  @doc false
  def remember(history, value) when is_list(history) do
    limits = limits()
    retained = retain(value)

    entries =
      [retained | history]
      |> Enum.take(limits.history_items)
      |> take_bytes(limits.history_bytes, [], 0)

    {retained, entries}
  end

  @doc false
  def summary?(%{retained: @summary_marker}), do: true
  def summary?(_value), do: false

  defp summary(value, preview_bytes) do
    %{
      retained: @summary_marker,
      kind: kind(value),
      bytes: external_size(value),
      fingerprint: value |> :erlang.phash2() |> Integer.to_string(16),
      preview: inspect(value, limit: 20, printable_limit: preview_bytes, width: 80)
    }
  end

  defp kind(value) when is_binary(value), do: :binary
  defp kind(value) when is_map(value), do: :map
  defp kind(value) when is_list(value), do: :list
  defp kind(value) when is_tuple(value), do: :tuple
  defp kind(value) when is_atom(value), do: :atom
  defp kind(_value), do: :term

  defp take_bytes([], _maximum, retained, _used), do: Enum.reverse(retained)

  defp take_bytes([entry | rest], maximum, retained, used) do
    size = external_size(entry)

    if used + size <= maximum do
      take_bytes(rest, maximum, [entry | retained], used + size)
    else
      Enum.reverse(retained)
    end
  end

  defp external_size(value) do
    :erlang.external_size(value)
  rescue
    _error -> @hard_max_history_bytes + 1
  end

  defp limits do
    configured = Application.get_env(:iex_code, :agent_state_retention, [])

    %{
      inline_bytes:
        positive(
          config_value(configured, :inline_bytes),
          @default_inline_bytes,
          @hard_max_inline_bytes
        ),
      preview_bytes:
        positive(
          config_value(configured, :preview_bytes),
          @default_preview_bytes,
          @hard_max_preview_bytes
        ),
      history_items:
        positive(
          config_value(configured, :history_items),
          @default_history_items,
          @hard_max_history_items
        ),
      history_bytes:
        positive(
          config_value(configured, :history_bytes),
          @default_history_bytes,
          @hard_max_history_bytes
        )
    }
  end

  defp config_value(configured, key) when is_map(configured), do: Map.get(configured, key)
  defp config_value(configured, key) when is_list(configured), do: Keyword.get(configured, key)
  defp config_value(_configured, _key), do: nil

  defp positive(value, _default, maximum) when is_integer(value) and value > 0,
    do: min(value, maximum)

  defp positive(_value, default, _maximum), do: default
end
