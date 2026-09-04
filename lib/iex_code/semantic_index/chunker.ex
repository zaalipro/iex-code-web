defmodule IexCode.SemanticIndex.Chunker do
  @moduledoc """
  Intelligent code chunking engine for offline semantic indexing.
  - Elixir files (`.ex`, `.exs`): AST symbol decomposition via `ASTSearch.Extractor`
    (modules, functions, macros, types, callbacks) with contextual symbol signatures.
  - Non-Elixir / documentation files (`.md`, `.json`, `.js`, etc.): windowed sliding line chunking
    (50 lines per chunk, 10 lines overlap).
  """

  alias IexCode.Tools.ASTSearch.Extractor

  @doc """
  Decomposes a source file into indexable semantic chunks.
  Returns a list of chunk maps.
  """
  @spec chunk_file(String.t(), String.t()) :: [map()]
  def chunk_file(file_path, content) when is_binary(file_path) and is_binary(content) do
    ext = Path.extname(file_path) |> String.downcase()

    if ext in [".ex", ".exs"] do
      chunk_elixir_file(file_path, content)
    else
      chunk_text_file(file_path, content)
    end
  end

  # ============================================================================
  # Elixir AST Chunking
  # ============================================================================

  defp chunk_elixir_file(file_path, content) do
    case Extractor.extract(content, file_path) do
      {:ok, symbols} when is_list(symbols) and symbols != [] ->
        symbols
        |> Enum.with_index()
        |> Enum.map(fn {sym, idx} ->
          type_str = to_string(sym.type)
          name_str = to_string(sym.name)
          end_line = sym[:end_line] || sym.line + max(1, length(String.split(sym.code, "\n")) - 1)

          context_header =
            "File: #{file_path} | #{type_str} #{name_str}" <>
              if(sym[:arity], do: "/#{sym.arity}", else: "")

          chunk_content = "#{context_header}\n\n#{sym.code}"

          chunk_type =
            cond do
              type_str in ["def", "defp", "function"] -> "function"
              type_str in ["defmodule", "module"] -> "module"
              type_str in ["defmacro", "macro"] -> "macro"
              type_str in ["spec", "@spec"] -> "spec"
              type_str in ["type", "@type"] -> "type"
              type_str in ["doc", "moduledoc", "@doc", "@moduledoc"] -> "doc"
              true -> type_str
            end

          %{
            chunk_index: idx,
            chunk_type: chunk_type,
            symbol_name: name_str,
            symbol_type: type_str,
            start_line: sym.line,
            end_line: end_line,
            content: chunk_content
          }
        end)

      _ ->
        chunk_text_file(file_path, content)
    end
  end

  # ============================================================================
  # Windowed Line Chunking
  # ============================================================================

  defp chunk_text_file(file_path, content) do
    lines = String.split(content, "\n")
    total_lines = length(lines)

    if total_lines <= 50 do
      [
        %{
          chunk_index: 0,
          chunk_type: "text",
          symbol_name: Path.basename(file_path),
          symbol_type: "file",
          start_line: 1,
          end_line: max(1, total_lines),
          content: "File: #{file_path} [lines 1-#{max(1, total_lines)}]\n\n#{content}"
        }
      ]
    else
      chunk_size = 50
      step = 40

      lines
      |> Enum.chunk_every(chunk_size, step, :discard)
      |> Enum.with_index()
      |> Enum.map(fn {chunk_lines, idx} ->
        start_line = idx * step + 1
        end_line = min(total_lines, start_line + length(chunk_lines) - 1)
        chunk_text = Enum.join(chunk_lines, "\n")

        %{
          chunk_index: idx,
          chunk_type: "text",
          symbol_name: nil,
          symbol_type: nil,
          start_line: start_line,
          end_line: end_line,
          content: "File: #{file_path} [lines #{start_line}-#{end_line}]\n\n#{chunk_text}"
        }
      end)
    end
  end
end
