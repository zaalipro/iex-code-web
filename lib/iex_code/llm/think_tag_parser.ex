defmodule IexCode.LLM.ThinkTagParser do
  @moduledoc """
  Stateful parser for extracting `<think>...</think>` tags from streaming chunks
  and completed strings without boundary splits or UI corruption.
  """

  defstruct state: :outside, buffer: ""

  @type state :: :outside | :inside
  @type t :: %__MODULE__{
          state: state(),
          buffer: String.t()
        }

  @doc "Creates a new parser state struct."
  def new, do: %__MODULE__{}

  @doc """
  Processes an incremental stream delta.
  Returns `{parsed_text, parsed_reasoning, updated_state}`.
  """
  def parse_stream_delta(delta, state \\ nil) when is_binary(delta) do
    parser =
      case state do
        %__MODULE__{} = p -> p
        _ -> new()
      end

    process_chunk(parser, delta)
  end

  @doc """
  Processes an incremental chunk with a parser struct.
  Returns `{clean_text, reasoning_chunk, updated_parser}`.
  """
  def process_chunk(%__MODULE__{} = parser, chunk) when is_binary(chunk) do
    data = parser.buffer <> chunk
    do_process(parser.state, data, "", "")
  end

  @doc """
  Flushes any trailing buffered characters in the parser.
  Returns `{trailing_text, trailing_reasoning, reset_parser}`.
  """
  def flush(%__MODULE__{state: :outside, buffer: buf}) do
    {buf, "", %__MODULE__{state: :outside, buffer: ""}}
  end

  def flush(%__MODULE__{state: :inside, buffer: buf}) do
    {"", buf, %__MODULE__{state: :inside, buffer: ""}}
  end

  @doc """
  Extracts think blocks from a completed non-streaming string.
  Returns `{reasoning, clean_text}`.
  """
  def extract(text) when is_binary(text) do
    case Regex.scan(~r/<think>(.*?)<\/think>/s, text) do
      [] ->
        {nil, text}

      matches ->
        thoughts =
          matches
          |> Enum.map(fn [_, thought] -> String.trim(thought) end)
          |> Enum.join("\n\n")

        clean =
          text
          |> String.replace(~r/<think>.*?<\/think>/s, "")
          |> String.trim()

        {thoughts, clean}
    end
  end

  def extract(other), do: {nil, to_string(other || "")}

  # --- Internal State Machine ---

  defp do_process(:outside, text, text_acc, reason_acc) do
    case String.split(text, "<think>", parts: 2) do
      [before_think, after_think] ->
        do_process(:inside, after_think, text_acc <> before_think, reason_acc)

      [plain] ->
        {safe, pending} = split_potential_tag(plain, "<think>")
        {text_acc <> safe, reason_acc, %__MODULE__{state: :outside, buffer: pending}}
    end
  end

  defp do_process(:inside, text, text_acc, reason_acc) do
    case String.split(text, "</think>", parts: 2) do
      [thought, after_thought] ->
        do_process(:outside, after_thought, text_acc, reason_acc <> thought)

      [plain_thought] ->
        {safe, pending} = split_potential_tag(plain_thought, "</think>")
        {text_acc, reason_acc <> safe, %__MODULE__{state: :inside, buffer: pending}}
    end
  end

  defp split_potential_tag(str, tag) do
    tag_len = String.length(tag)

    # Check for non-empty suffixes of str that match a non-empty prefix of tag
    prefix_len =
      Enum.find((tag_len - 1)..1//-1, 0, fn len ->
        prefix = String.slice(tag, 0, len)
        String.ends_with?(str, prefix)
      end)

    if prefix_len > 0 do
      cut = String.length(str) - prefix_len
      {String.slice(str, 0, cut), String.slice(str, cut..-1//1)}
    else
      {str, ""}
    end
  end
end
