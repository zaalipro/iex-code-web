defmodule IexCode.LLM.ContextCompactor do
  @moduledoc """
  Context window compaction and token management engine.

  Monitors conversation token volume against the configured threshold
  (`context_window_tokens * context_prune_threshold_percent / 100`) and
  executes one of three compaction strategies when exceeded:

    * `"token_compaction"`: Prunes voluminous tool outputs and diffs to concise excerpts.
    * `"rolling_summary"`: Condenses older conversation turns into a structured summary checkpoint.
    * `"sliding_window"`: Retains the root objective and latest K turns.
  """

  alias IexCode.Settings.AppSettings

  @default_window_tokens 128_000
  @default_threshold_percent 75
  @default_keep_recent_turns 6
  @max_tool_output_chars 1_500

  @doc """
  Compacts the message list if estimated tokens exceed the configured threshold.
  """
  @spec compact(list(map()), AppSettings.t() | map() | nil, String.t() | nil) :: list(map())
  def compact(messages, settings, model_name \\ nil)
  def compact([], _settings, _model_name), do: []

  def compact(messages, settings, model_name) when is_list(messages) do
    window_tokens = get_setting(settings, :context_window_tokens, @default_window_tokens)

    threshold_percent =
      get_setting(settings, :context_prune_threshold_percent, @default_threshold_percent)

    strategy = get_setting(settings, :context_compaction_strategy, "token_compaction")
    keep_turns = get_setting(settings, :keep_recent_turns, @default_keep_recent_turns)

    trigger_tokens = trunc(window_tokens * (threshold_percent / 100))
    current_tokens = estimate_tokens(messages)

    if current_tokens > trigger_tokens do
      apply_strategy(strategy, messages, trigger_tokens, keep_turns, model_name)
    else
      messages
    end
  end

  @doc """
  Estimates the token count for a list of messages or a single message/string.
  Roughly 1 token ≈ 4 bytes of text plus per-message overhead.
  """
  @spec estimate_tokens(list(map()) | map() | String.t()) :: integer()
  def estimate_tokens(messages) when is_list(messages) do
    Enum.reduce(messages, 0, fn msg, acc ->
      acc + estimate_message_tokens(msg) + 4
    end)
  end

  def estimate_tokens(msg) when is_map(msg) do
    estimate_message_tokens(msg)
  end

  def estimate_tokens(text) when is_binary(text) do
    div(byte_size(text), 4) + 1
  end

  def estimate_tokens(_), do: 0

  defp estimate_message_tokens(msg) when is_map(msg) do
    content = get_message_field(msg, :content) || ""
    role = get_message_field(msg, :role) || ""
    tool_calls = get_message_field(msg, :tool_calls)

    content_tokens =
      cond do
        is_binary(content) -> div(byte_size(content), 4) + 1
        is_list(content) -> div(byte_size(inspect(content)), 4) + 1
        true -> 0
      end

    tool_tokens =
      if is_list(tool_calls) do
        div(byte_size(inspect(tool_calls)), 4) + 2
      else
        0
      end

    role_tokens = div(byte_size(to_string(role)), 4) + 1
    content_tokens + tool_tokens + role_tokens
  end

  defp estimate_message_tokens(_), do: 0

  defp apply_strategy("token_compaction", messages, target_tokens, keep_turns, model_name) do
    compacted = Enum.map(messages, &compact_tool_message/1)

    if estimate_tokens(compacted) > target_tokens do
      apply_strategy("sliding_window", compacted, target_tokens, keep_turns, model_name)
    else
      compacted
    end
  end

  defp apply_strategy("sliding_window", messages, _target_tokens, keep_turns, _model_name) do
    case messages do
      [root | rest] when length(rest) > keep_turns ->
        recent = Enum.take(rest, -keep_turns)
        [root | recent]

      _other ->
        messages
    end
  end

  defp apply_strategy("rolling_summary", messages, target_tokens, keep_turns, model_name) do
    case messages do
      [root | rest] when length(rest) > keep_turns ->
        older_count = length(rest) - keep_turns
        older = Enum.take(rest, older_count)
        recent = Enum.take(rest, -keep_turns)

        summary_lines = build_summary_lines(older)

        root_tokens = estimate_tokens([root])
        recent_tokens = estimate_tokens(recent)
        header_text = "Summary of earlier conversation history:\n"
        header_tokens = estimate_tokens(header_text)
        base_tokens = root_tokens + recent_tokens + header_tokens

        available_tokens = target_tokens - base_tokens

        pruned_lines =
          cond do
            available_tokens > 0 ->
              prune_summary_lines_to_budget(summary_lines, available_tokens)

            length(older) <= keep_turns * 2 ->
              summary_lines

            true ->
              []
          end

        if pruned_lines == [] and available_tokens <= 0 and length(older) > keep_turns * 2 do
          apply_strategy("sliding_window", messages, target_tokens, keep_turns, model_name)
        else
          summary_text = Enum.join(pruned_lines, "\n")

          summary_msg =
            if is_atom_keyed?(root) do
              %{
                role: "system",
                content: header_text <> summary_text
              }
            else
              %{
                "role" => "system",
                "content" => header_text <> summary_text
              }
            end

          compacted = [root, summary_msg | recent]

          if estimate_tokens(compacted) > target_tokens and length(older) > keep_turns * 2 do
            apply_strategy("sliding_window", messages, target_tokens, keep_turns, model_name)
          else
            compacted
          end
        end

      _other ->
        messages
    end
  end

  defp apply_strategy(_unknown_strategy, messages, target_tokens, keep_turns, model_name) do
    apply_strategy("token_compaction", messages, target_tokens, keep_turns, model_name)
  end

  @doc """
  Compacts a single message if it contains bulky tool outputs.
  """
  def compact_tool_message(msg) when is_map(msg) do
    role = to_string(get_message_field(msg, :role) || "")
    content = get_message_field(msg, :content)

    if (role in ["tool", "system"] or is_tool_result_content?(content)) and is_binary(content) and
         byte_size(content) > @max_tool_output_chars do
      pruned_content = prune_bulky_content(content)
      put_message_field(msg, :content, pruned_content)
    else
      msg
    end
  end

  def compact_tool_message(msg), do: msg

  defp is_tool_result_content?(content) when is_binary(content) do
    String.contains?(content, "Exit Code") or
      String.contains?(content, "matches found") or
      String.contains?(content, "Showing lines") or
      String.contains?(content, "diff --git")
  end

  defp is_tool_result_content?(_), do: false

  defp prune_bulky_content(content) do
    lines = String.split(content, ~r/\r?\n/)
    total_lines = length(lines)

    exit_code_line = Enum.find(lines, &String.starts_with?(&1, "Exit Code"))

    if total_lines <= 16 do
      compact_few_lines(content, lines, total_lines, exit_code_line)
    else
      compact_many_lines(lines, total_lines, exit_code_line)
    end
  end

  defp compact_few_lines(content, _lines, _total_lines, exit_code_line) do
    total_bytes = byte_size(content)
    head_bytes = 600
    tail_bytes = 300

    head = String.slice(content, 0, head_bytes)
    tail = String.slice(content, -tail_bytes, tail_bytes)
    compacted_bytes = max(0, total_bytes - (byte_size(head) + byte_size(tail)))

    prepend_exit_code =
      if exit_code_line && not String.contains?(head, exit_code_line) do
        exit_code_line <> "\n"
      end

    banner = "\n... [compacted #{compacted_bytes} bytes of verbose tool output] ...\n"

    [prepend_exit_code, head, banner, tail]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("")
  end

  defp compact_many_lines(lines, total_lines, exit_code_line) do
    header_lines = Enum.take(lines, 12)
    footer_lines = Enum.take(lines, -4)

    prepend_exit_code =
      if exit_code_line && exit_code_line not in header_lines do
        exit_code_line <> "\n"
      end

    omitted_lines = max(0, total_lines - 16)

    parts = [
      prepend_exit_code,
      Enum.join(header_lines, "\n"),
      "\n... [compacted #{omitted_lines} lines of verbose tool output] ...\n",
      Enum.join(footer_lines, "\n")
    ]

    parts |> Enum.reject(&is_nil/1) |> Enum.join("")
  end

  defp build_summary_lines(messages) do
    Enum.map(messages, fn msg ->
      role = to_string(get_message_field(msg, :role) || "unknown")
      content = to_string(get_message_field(msg, :content) || "")
      first_line = content |> String.split("\n") |> List.first() || ""
      snippet = String.slice(first_line, 0, 120)

      case role do
        "user" -> "- User requested: #{snippet}"
        "assistant" -> "- Assistant planned: #{snippet}"
        "tool" -> "- Tool executed: #{snippet}"
        _ -> "- #{role}: #{snippet}"
      end
    end)
  end

  defp prune_summary_lines_to_budget(lines, available_tokens) do
    total_text = Enum.join(lines, "\n")

    if estimate_tokens(total_text) <= available_tokens do
      lines
    else
      lines
      |> Enum.reverse()
      |> Enum.reduce_while({[], 0}, fn line, {acc, tokens} ->
        line_tokens = estimate_tokens(line <> "\n")

        if tokens + line_tokens <= available_tokens do
          {:cont, {[line | acc], tokens + line_tokens}}
        else
          {:halt, {acc, tokens}}
        end
      end)
      |> elem(0)
    end
  end

  defp get_setting(nil, _field, default), do: default

  defp get_setting(%AppSettings{} = settings, field, default) do
    case Map.get(settings, field) do
      nil -> default
      val -> val
    end
  end

  defp get_setting(settings, field, default) when is_map(settings) do
    Map.get(settings, field) || Map.get(settings, to_string(field)) || default
  end

  defp get_message_field(map, field) when is_map(map) and is_atom(field) do
    Map.get(map, field) || Map.get(map, Atom.to_string(field))
  end

  defp put_message_field(map, field, val) when is_map(map) and is_atom(field) do
    if Map.has_key?(map, field) do
      Map.put(map, field, val)
    else
      Map.put(map, Atom.to_string(field), val)
    end
  end

  defp is_atom_keyed?(map) when is_map(map) do
    Enum.any?(Map.keys(map), &is_atom/1)
  end

  defp is_atom_keyed?(_), do: true
end
