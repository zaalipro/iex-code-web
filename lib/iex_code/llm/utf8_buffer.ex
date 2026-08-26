defmodule IexCode.LLM.UTF8Buffer do
  @moduledoc """
  Stateful buffer handling multibyte UTF-8 code point boundary splits
  across 2-, 3-, and 4-byte sequences in streaming network chunks.
  Prevents UTF-8 encoding crashes when chunks slice characters mid-codepoint.
  """

  @type state :: binary()

  @doc """
  Initializes an empty buffer state.
  """
  @spec new() :: state()
  def new, do: <<>>

  @doc """
  Combines the accumulated unparsed binary with a new raw chunk,
  emitting the maximum valid UTF-8 binary prefix and returning any
  trailing incomplete byte sequence to be preserved for the next chunk.

  ## Examples

      iex> IexCode.LLM.UTF8Buffer.process_bytes(<<>>, "hello")
      {"hello", <<>>}

      # 4-byte emoji 🐝 (<<240, 159, 144, 157>>) split across chunks
      iex> {valid1, rest1} = IexCode.LLM.UTF8Buffer.process_bytes(<<>>, "Bee: " <> <<240, 159>>)
      {"Bee: ", <<240, 159>>}

      iex> {valid2, rest2} = IexCode.LLM.UTF8Buffer.process_bytes(rest1, <<144, 157>> <> " ready")
      {"🐝 ready", <<>>}
  """
  @spec process_bytes(state(), binary() | nil) ::
          {valid_binary :: String.t(), rest_state :: state()}
  def process_bytes(acc, raw_chunk) do
    data = (acc || <<>>) <> (raw_chunk || <<>>)
    do_process(data, <<>>)
  end

  @doc """
  Flushes any remaining bytes in the buffer upon stream completion.
  If the buffer holds invalid incomplete bytes at the end of the stream,
  they are sanitized to unicode replacement characters.
  """
  @spec flush(state()) :: {String.t(), <<>>}
  def flush(<<>>), do: {"", <<>>}

  def flush(acc) do
    case :unicode.characters_to_binary(acc, :utf8, :utf8) do
      valid when is_binary(valid) ->
        {valid, <<>>}

      _ ->
        sanitized =
          case Code.ensure_loaded(String) && function_exported?(String, :replace_invalid, 2) do
            true -> String.replace_invalid(acc, "\uFFFD")
            false -> sanitize_invalid(acc)
          end

        {sanitized, <<>>}
    end
  end

  # --- Internal Helpers ---

  defp do_process(<<>>, valid_acc), do: {valid_acc, <<>>}

  defp do_process(bin, valid_acc) do
    case :unicode.characters_to_binary(bin, :utf8, :utf8) do
      valid when is_binary(valid) ->
        {valid_acc <> valid, <<>>}

      {:incomplete, valid, rest} ->
        {valid_acc <> valid, rest}

      {:error, valid, <<_bad_byte, rest::binary>>} ->
        do_process(rest, valid_acc <> valid <> "\uFFFD")

      {:error, valid, <<>>} ->
        {valid_acc <> valid, <<>>}
    end
  end

  defp sanitize_invalid(<<>>), do: ""

  defp sanitize_invalid(<<char::utf8, rest::binary>>) do
    <<char::utf8>> <> sanitize_invalid(rest)
  end

  defp sanitize_invalid(<<_bad::binary-size(1), rest::binary>>) do
    "\uFFFD" <> sanitize_invalid(rest)
  end
end
