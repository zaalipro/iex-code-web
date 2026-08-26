defmodule IexCode.Tools.ASTSearch do
  @moduledoc """
  AST-Aware Search Engine for Elixir projects.
  Traverses Elixir source code AST to locate modules, functions, macros,
  @spec type signatures, @doc/@moduledoc documentation, and module attributes.
  """

  alias IexCode.Tools.ASTSearch.{Extractor, Query, Formatter}

  require Logger

  @type symbol_entry :: Extractor.symbol_entry()
  @type query_spec :: String.t() | map() | keyword()

  @default_limit 500

  @doc """
  Searches all .ex/.exs files in `project_root` matching `query`.

  Options:

    * `:path` - optional subdirectory (relative to `project_root`) or an
      absolute directory/file path to scope the search to.
    * `:limit` - maximum number of results returned (default #{@default_limit}).
      Prevents formatter output from blowing up the LLM context.

  Files that fail to parse or read are skipped with a logged warning instead
  of crashing the search.
  """
  @spec search(Path.t(), query_spec(), keyword()) ::
          {:ok, [symbol_entry()]} | {:error, term()}
  def search(project_root, query, opts \\ []) do
    sub_path =
      case query do
        %{path: p} when is_binary(p) and p != "" -> p
        %{"path" => p} when is_binary(p) and p != "" -> p
        _ -> Keyword.get(opts, :path, "")
      end

    search_dir =
      cond do
        sub_path == "" -> project_root
        Path.type(sub_path) == :absolute -> sub_path
        true -> Path.join(project_root, sub_path)
      end

    if File.exists?(search_dir) do
      files = find_elixir_files(search_dir)

      all_symbols =
        Enum.flat_map(files, fn file_path ->
          rel_path = relative_path(file_path, project_root)

          try do
            case File.read(file_path) do
              {:ok, content} ->
                case Extractor.extract(content, rel_path) do
                  {:ok, symbols} ->
                    symbols

                  {:error, reason} ->
                    Logger.warning(
                      "ASTSearch: skipping #{rel_path}: parse error #{inspect(reason)}"
                    )

                    []
                end

              {:error, reason} ->
                Logger.warning("ASTSearch: skipping #{rel_path}: read error #{inspect(reason)}")
                []
            end
          rescue
            e ->
              Logger.warning("ASTSearch: skipping #{rel_path}: #{Exception.message(e)}")
              []
          end
        end)

      case Query.filter(all_symbols, query) do
        {:error, _reason} = error ->
          error

        filtered ->
          {:ok, Enum.take(filtered, Keyword.get(opts, :limit, @default_limit))}
      end
    else
      {:error, :path_not_found}
    end
  end

  @doc """
  Searches a single source file for AST symbols matching `query`.

  Accepts the same `:limit` option as `search/3`.
  """
  @spec search_file(Path.t(), query_spec(), keyword()) ::
          {:ok, [symbol_entry()]} | {:error, term()}
  def search_file(file_path, query, opts \\ []) do
    if File.exists?(file_path) do
      case File.read(file_path) do
        {:ok, content} ->
          case Extractor.extract(content, file_path) do
            {:ok, symbols} ->
              case Query.filter(symbols, query) do
                {:error, _reason} = error ->
                  error

                filtered ->
                  {:ok, Enum.take(filtered, Keyword.get(opts, :limit, @default_limit))}
              end

            {:error, reason} ->
              {:error, reason}
          end

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :file_not_found}
    end
  end

  @doc """
  Extracts all AST symbols from Elixir source code string.
  """
  @spec extract_symbols(String.t(), Path.t()) ::
          {:ok, [symbol_entry()]} | {:error, term()}
  def extract_symbols(source_code, file_path \\ "") when is_binary(source_code) do
    Extractor.extract(source_code, file_path)
  end

  @doc """
  Formats symbol search results as a string.
  """
  @spec format_results([symbol_entry()], keyword()) :: String.t()
  defdelegate format_results(entries, opts \\ []), to: Formatter

  # --- File Discovery Helpers ---

  # Matched against the path relative to the searched directory, so a project
  # subdirectory named e.g. `tmp` (ExUnit's :tmp_dir fixture root) is searched.
  @excluded_dirs ["/_build/", "/deps/", "/node_modules/", "/.git/", "/.agents/"]

  defp find_elixir_files(dir) do
    if File.regular?(dir) do
      [dir]
    else
      prefix = String.trim_trailing(to_string(dir), "/") <> "/"

      Path.wildcard(Path.join(dir, "**/*.{ex,exs}"))
      |> Enum.reject(fn p ->
        rel = "/" <> String.replace_prefix(p, prefix, "")
        Enum.any?(@excluded_dirs, &String.contains?(rel, &1))
      end)
    end
  end

  # Relative path for display; falls back to the absolute path when the file
  # lives outside `project_root` (possible with absolute path queries).
  defp relative_path(file_path, project_root) do
    root = project_root |> to_string() |> String.trim_trailing("/")

    cond do
      file_path == root -> Path.basename(file_path)
      String.starts_with?(file_path, root <> "/") -> Path.relative_to(file_path, root)
      true -> file_path
    end
  end
end
