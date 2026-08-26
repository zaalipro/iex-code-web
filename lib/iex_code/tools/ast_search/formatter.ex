defmodule IexCode.Tools.ASTSearch.Formatter do
  @moduledoc """
  Output formatter for ASTSearch results.
  """

  alias IexCode.Tools.ASTSearch.Extractor

  @default_limit 200

  @doc """
  Formats a single symbol entry into a readable location string.
  """
  @spec format_symbol(Extractor.symbol_entry()) :: String.t()
  def format_symbol(entry) do
    loc = "#{entry.file}:#{entry.line}"

    type_tag =
      cond do
        entry.type in [:module, :defmodule] -> "[module]"
        entry.type in [:function, :def, :defp] -> "[function]"
        entry.type in [:macro, :defmacro, :defmacrop] -> "[macro]"
        true -> "[#{entry.type}]"
      end

    name_str =
      cond do
        entry.type in [:module, :defmodule] ->
          entry.name

        entry.type in [:function, :def, :defp, :macro, :defmacro, :defmacrop, :spec, :callback] and
            entry.arity != nil ->
          mod = if entry.module, do: "#{entry.module}.", else: ""
          "#{mod}#{entry.name}/#{entry.arity}"

        true ->
          mod = if entry.module, do: "#{entry.module}.", else: ""
          "#{mod}#{entry.name}"
      end

    vis = if entry.visibility == :private, do: " (private)", else: ""

    "#{loc} #{type_tag} #{name_str}#{vis}"
  end

  @doc """
  Formats a list of symbol entries with optional code snippets.

  Options:

    * `:include_code` - include code snippets (default `false`).
    * `:limit` - maximum number of entries to format (default #{@default_limit}).
      When more entries are given, a truncation notice is appended so the
      output can never silently blow up the LLM context.
  """
  @spec format_results([Extractor.symbol_entry()], keyword()) :: String.t()
  def format_results(entries, opts \\ [])
  def format_results([], _opts), do: "No AST symbols found matching query."

  def format_results(entries, opts) do
    include_code? = Keyword.get(opts, :include_code, false)
    limit = Keyword.get(opts, :limit, @default_limit)
    {shown, hidden} = Enum.split(entries, limit)

    body =
      shown
      |> Enum.map(fn entry ->
        header = format_symbol(entry)

        if include_code? and entry.code do
          "#{header}\n  " <> String.replace(entry.code, "\n", "\n  ")
        else
          header
        end
      end)
      |> Enum.join("\n")

    case hidden do
      [] ->
        body

      _ ->
        body <>
          "\n... (#{length(hidden)} more results not shown; refine the query or pass a higher :limit)"
    end
  end
end
