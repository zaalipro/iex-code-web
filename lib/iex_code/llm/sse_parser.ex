defmodule IexCode.LLM.SSEParser do
  @moduledoc """
  Parser for Server-Sent Events (SSE) supporting both OpenAI-compatible
  and Anthropic Claude streaming formats.
  Handles line framing, delta extraction, tool call chunks, and stop signals.
  """
  require Logger

  defstruct event: nil, data_lines: [], line_buffer: "", at_start?: true

  @type t :: %__MODULE__{
          event: String.t() | nil,
          data_lines: [String.t()],
          line_buffer: String.t(),
          at_start?: boolean()
        }

  @type sse_event :: %{
          event: String.t(),
          data: String.t()
        }

  @type delta_result ::
          {:delta,
           %{
             text: String.t(),
             tool_calls: [map()],
             reasoning: String.t()
           }}
          | {:done, reason :: atom() | String.t()}
          | {:done, reason :: atom() | String.t(), final_delta :: map()}
          | {:error, term()}
          | :ignore

  @doc """
  Creates a new SSE parser state.
  """
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Consumes a UTF-8 text chunk, frames complete SSE lines and events,
  and returns `{[sse_event], new_state}`.
  """
  @spec parse(t(), String.t()) :: {[sse_event()], t()}
  def parse(%__MODULE__{} = state, text_chunk) do
    {chunk, state} = strip_bom(state, text_chunk || "")
    combined = state.line_buffer <> chunk
    lines = String.split(combined, ~r/\r\n|\r|\n/)
    {complete_lines, [incomplete_line]} = Enum.split(lines, -1)

    {events, final_state} =
      Enum.reduce(
        complete_lines,
        {[], %{state | line_buffer: incomplete_line}},
        fn line, {ev_acc, st} ->
          process_line(line, ev_acc, st)
        end
      )

    {events, final_state}
  end

  # Strip a leading UTF-8 BOM emitted by some providers at stream start.
  defp strip_bom(%__MODULE__{at_start?: true} = state, "\uFEFF" <> rest),
    do: {rest, %{state | at_start?: false}}

  defp strip_bom(%__MODULE__{at_start?: true} = state, chunk),
    do: {chunk, %{state | at_start?: false}}

  defp strip_bom(state, chunk), do: {chunk, state}

  @doc """
  Parses a raw chunk directly (convenience wrapper).
  """
  @spec parse_chunk(String.t()) :: {:ok, [sse_event()]} | {:done} | {:error, term()}
  def parse_chunk(chunk) do
    {events, _st} = parse(new(), chunk)
    {:ok, events}
  end

  @doc """
  Translates a generic SSE event into a structured delta result based on provider format.
  Provider can be "openai", "anthropic", or "gemini".
  """
  @spec parse_event(sse_event(), String.t()) :: delta_result()
  def parse_event(%{data: "[DONE]"}, _provider), do: {:done, :stop}
  def parse_event(%{event: "message_stop"}, "anthropic"), do: {:done, :stop}

  # --- Anthropic Provider Parsing ---
  def parse_event(%{event: "message_start", data: json_str}, "anthropic") do
    case Jason.decode(String.trim(json_str)) do
      {:ok, %{"message" => %{"usage" => usage}}} when is_map(usage) ->
        {:delta, %{text: "", tool_calls: [], reasoning: "", usage: usage}}

      _ ->
        :ignore
    end
  end

  def parse_event(%{event: "content_block_delta", data: json_str}, "anthropic") do
    case Jason.decode(String.trim(json_str)) do
      {:ok, %{"delta" => %{"type" => "text_delta", "text" => text}}} ->
        {:delta, %{text: text, tool_calls: [], reasoning: ""}}

      {:ok, %{"delta" => %{"type" => "thinking_delta", "thinking" => thinking}}} ->
        {:delta, %{text: "", tool_calls: [], reasoning: thinking}}

      {:ok, %{"index" => idx, "delta" => %{"type" => "input_json_delta", "partial_json" => pj}}} ->
        {:delta,
         %{
           text: "",
           tool_calls: [%{"index" => idx, "function" => %{"arguments" => pj}}],
           reasoning: ""
         }}

      {:ok, _} ->
        :ignore

      {:error, err} ->
        {:error, err}
    end
  end

  def parse_event(%{event: "content_block_start", data: json_str}, "anthropic") do
    case Jason.decode(String.trim(json_str)) do
      {:ok,
       %{"index" => idx, "content_block" => %{"type" => "tool_use", "id" => id, "name" => name}}} ->
        {:delta,
         %{
           text: "",
           tool_calls: [
             %{
               "index" => idx,
               "id" => id,
               "function" => %{"name" => name, "arguments" => ""}
             }
           ],
           reasoning: ""
         }}

      _ ->
        :ignore
    end
  end

  def parse_event(%{event: "message_delta", data: json_str}, "anthropic") do
    case Jason.decode(String.trim(json_str)) do
      {:ok, %{"delta" => %{"stop_reason" => stop_reason}} = json} ->
        case json["usage"] do
          usage when is_map(usage) ->
            {:done, stop_reason, %{text: "", tool_calls: [], reasoning: "", usage: usage}}

          _ ->
            {:done, stop_reason}
        end

      {:ok, %{"usage" => usage}} when is_map(usage) ->
        {:delta, %{text: "", tool_calls: [], reasoning: "", usage: usage}}

      _ ->
        :ignore
    end
  end

  def parse_event(%{event: "error", data: json_str}, "anthropic") do
    case Jason.decode(String.trim(json_str)) do
      {:ok, %{"error" => err}} -> {:error, err}
      _ -> {:error, json_str}
    end
  end

  # --- OpenAI Provider Parsing ---
  def parse_event(%{data: json_str}, "openai") do
    trimmed = String.trim(json_str)

    if trimmed == "[DONE]" do
      {:done, :stop}
    else
      case Jason.decode(trimmed) do
        {:ok, %{"choices" => [%{"delta" => delta} = choice | _]} = json} ->
          finish_reason = choice["finish_reason"]
          tool_calls = delta["tool_calls"] || []
          text = delta["content"] || ""
          reasoning = delta["reasoning_content"] || delta["reasoning"] || ""

          delta_map =
            with_usage(%{text: text, tool_calls: tool_calls, reasoning: reasoning}, json)

          if finish_reason != nil and finish_reason != "" do
            {:done, finish_reason, delta_map}
          else
            {:delta, delta_map}
          end

        # usage-only terminal chunk (stream_options.include_usage)
        {:ok, %{"usage" => usage}} when is_map(usage) ->
          {:delta, %{text: "", tool_calls: [], reasoning: "", usage: usage}}

        {:ok, %{"error" => error_map}} ->
          {:error, error_map}

        {:ok, _other} ->
          :ignore

        {:error, err} ->
          {:error, err}
      end
    end
  end

  def parse_event(_event, _provider), do: :ignore

  defp with_usage(delta_map, json) do
    case json["usage"] do
      usage when is_map(usage) -> Map.put(delta_map, :usage, usage)
      _ -> delta_map
    end
  end

  # --- Internal SSE Line Processors ---

  # Dispatch an event only when it carries data; an `event:` line with no data
  # is dropped instead of dispatching an empty payload.
  defp process_line("", ev_acc, %{data_lines: [_ | _]} = st) do
    data_str = st.data_lines |> Enum.reverse() |> Enum.join("\n")
    event_type = st.event || "message"
    ev = %{event: event_type, data: data_str}
    {ev_acc ++ [ev], %{st | event: nil, data_lines: []}}
  end

  defp process_line("", ev_acc, st), do: {ev_acc, %{st | event: nil}}

  # Field values tolerate both "field: value" and "field:value"; per the SSE
  # spec a single leading space after the colon is stripped.
  defp process_line("event:" <> event_name, ev_acc, st) do
    {ev_acc, %{st | event: String.trim(strip_leading_space(event_name))}}
  end

  defp process_line("data:" <> data_content, ev_acc, %{data_lines: lines} = st) do
    {ev_acc, %{st | data_lines: [strip_leading_space(data_content) | lines]}}
  end

  defp process_line(":" <> _comment, ev_acc, st), do: {ev_acc, st}
  defp process_line(_other, ev_acc, st), do: {ev_acc, st}

  defp strip_leading_space(" " <> rest), do: rest
  defp strip_leading_space(rest), do: rest
end
