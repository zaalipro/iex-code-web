defmodule IexCode.Tools.ASTSearch do
  @moduledoc """
  Bounded AST-aware search for Elixir modules, functions, macros, specs, docs,
  attributes, types, and callbacks.

  Directory discovery never follows symlinks and never materializes a recursive
  wildcard. Each search has hard entry, file, per-file byte, aggregate byte,
  and result ceilings. `search/3` preserves the historical list result;
  `search_with_metadata/3` additionally reports why a scan was truncated.
  """

  alias IexCode.Execution.ResourceGovernor
  alias IexCode.Tools.ASTSearch.{Extractor, Formatter, Query}

  require Logger

  @type symbol_entry :: Extractor.symbol_entry()
  @type query_spec :: String.t() | map() | keyword()

  @default_limit 500
  @max_results 2_000
  @default_max_entries 20_000
  @max_entries 100_000
  @default_max_files 2_000
  @max_files 10_000
  @default_max_file_bytes 1 * 1_024 * 1_024
  @hard_max_file_bytes 4 * 1_024 * 1_024
  @default_max_total_bytes 32 * 1_024 * 1_024
  @hard_max_total_bytes 32 * 1_024 * 1_024
  @default_max_result_bytes 4 * 1_024 * 1_024
  @hard_max_result_bytes 8 * 1_024 * 1_024
  @default_max_depth 128
  @hard_max_depth 256
  @max_path_bytes 4_096
  @excluded_dirs MapSet.new(["_build", "deps", "node_modules", ".git", ".agents"])

  @type search_metadata :: %{
          results: [symbol_entry()],
          truncated?: boolean(),
          truncation_reasons: [atom()],
          scanned_entries: non_neg_integer(),
          scanned_files: non_neg_integer(),
          scanned_bytes: non_neg_integer(),
          skipped_large_files: non_neg_integer(),
          skipped_unreadable_files: non_neg_integer(),
          limits: map()
        }

  @doc """
  Searches a directory or file and returns a compatibility list of matching
  entries. Use `search_with_metadata/3` when the caller must distinguish a
  complete scan from a bounded partial scan.
  """
  @spec search(Path.t(), query_spec(), keyword()) ::
          {:ok, [symbol_entry()]} | {:error, term()}
  def search(project_root, query, opts \\ []) do
    case search_with_metadata(project_root, query, opts) do
      {:ok, %{results: results}} -> {:ok, results}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Runs the same bounded search as `search/3` and returns explicit scan metadata.

  The following options may lower the defaults (or raise them only up to hard
  ceilings): `:limit`, `:max_entries`, `:max_files`, `:max_file_bytes`,
  `:max_total_bytes`, `:max_result_bytes`, and `:max_depth`.
  """
  @spec search_with_metadata(Path.t(), query_spec(), keyword()) ::
          {:ok, search_metadata()} | {:error, term()}
  def search_with_metadata(project_root, query, opts \\ [])

  def search_with_metadata(project_root, query, opts)
      when is_binary(project_root) and is_list(opts) do
    ResourceGovernor.with_permit(
      :ast_scan,
      ResourceGovernor.admission_opts(opts, priority: :interactive, run_key: project_root),
      fn -> do_search_with_metadata(project_root, query, opts) end
    )
  end

  def search_with_metadata(_project_root, _query, _opts), do: {:error, :invalid_search}

  @doc """
  Searches a single bounded source file. This remains a compatibility list API;
  pass `return_metadata: true` to receive the metadata map.
  """
  @spec search_file(Path.t(), query_spec(), keyword()) ::
          {:ok, [symbol_entry()] | search_metadata()} | {:error, term()}
  def search_file(file_path, query, opts \\ []) do
    result = search_with_metadata(file_path, query, Keyword.put(opts, :path, ""))

    case {result, Keyword.get(opts, :return_metadata, false)} do
      {{:ok, metadata}, true} -> {:ok, metadata}
      {{:ok, %{results: results}}, false} -> {:ok, results}
      {{:error, :path_not_found}, _return_metadata?} -> {:error, :file_not_found}
      {{:error, _reason} = error, _return_metadata?} -> error
    end
  end

  @doc "Extracts all AST symbols from an already bounded source string."
  @spec extract_symbols(String.t(), Path.t()) ::
          {:ok, [symbol_entry()]} | {:error, term()}
  def extract_symbols(source_code, file_path \\ "") when is_binary(source_code) do
    Extractor.extract(source_code, file_path)
  end

  @doc "Formats symbol search results as a string."
  @spec format_results([symbol_entry()], keyword()) :: String.t()
  defdelegate format_results(entries, opts \\ []), to: Formatter

  defp do_search_with_metadata(project_root, query, opts) do
    with {:ok, matcher} <- Query.compile(query),
         {:ok, search_path} <- resolve_search_path(project_root, query, opts),
         {:ok, root_stat} <- File.lstat(search_path),
         true <- root_stat.type in [:regular, :directory] or {:error, :path_not_found} do
      limits = limits(opts)
      initial = initial_state(limits)

      state =
        case root_stat.type do
          :regular ->
            scan_file(
              search_path,
              relative_path(search_path, project_root),
              root_stat,
              initial,
              matcher
            )

          :directory ->
            walk_directory(
              search_path,
              relative_directory(search_path, project_root),
              0,
              initial,
              matcher
            )
        end

      {:ok, metadata(state)}
    else
      {:error, :enoent} -> {:error, :path_not_found}
      {:error, :enotdir} -> {:error, :path_not_found}
      {:error, _reason} = error -> error
      false -> {:error, :path_not_found}
    end
  end

  defp resolve_search_path(project_root, query, opts) do
    sub_path =
      case query do
        %{path: path} when is_binary(path) and path != "" -> path
        %{"path" => path} when is_binary(path) and path != "" -> path
        _query -> Keyword.get(opts, :path, "")
      end

    search_path =
      cond do
        sub_path in [nil, ""] -> project_root
        Path.type(sub_path) == :absolute -> sub_path
        true -> Path.join(project_root, sub_path)
      end

    if File.exists?(search_path), do: {:ok, search_path}, else: {:error, :path_not_found}
  end

  defp initial_state(limits) do
    %{
      limits: limits,
      results: [],
      result_count: 0,
      result_bytes: 0,
      scanned_entries: 0,
      scanned_files: 0,
      scanned_bytes: 0,
      skipped_large_files: 0,
      skipped_unreadable_files: 0,
      reasons: MapSet.new(),
      stop?: false
    }
  end

  defp walk_directory(path, relative, _depth, state, matcher) do
    case System.find_executable("find") do
      executable when is_binary(executable) ->
        port =
          Port.open({:spawn_executable, executable}, [
            :binary,
            :exit_status,
            :hide,
            args: find_args(Path.expand(path))
          ])

        try do
          collect_discovered_paths(port, Path.expand(path), relative, state, matcher, "")
        after
          close_discovery_port(port)
        end

      _missing ->
        state |> add_reason(:discovery_unavailable) |> Map.put(:stop?, true)
    end
  end

  defp find_args(root) do
    excluded_expression =
      @excluded_dirs
      |> Enum.sort()
      |> Enum.map(&["-name", &1])
      |> Enum.intersperse(["-o"])
      |> List.flatten()

    [root, "-type", "d", "("] ++
      excluded_expression ++ [")", "-prune", "-o", "-print0"]
  end

  defp collect_discovered_paths(port, root, relative_root, state, matcher, pending) do
    receive do
      {^port, {:data, data}} ->
        case consume_discovered_paths(
               pending <> data,
               root,
               relative_root,
               state,
               matcher
             ) do
          {:ok, state, pending} ->
            collect_discovered_paths(port, root, relative_root, state, matcher, pending)

          {:halt, state} ->
            state
        end

      {^port, {:exit_status, 0}} ->
        state

      {^port, {:exit_status, _status}} ->
        add_reason(state, :discovery_error)
    end
  end

  defp consume_discovered_paths(buffer, root, relative_root, state, matcher) do
    case :binary.match(buffer, <<0>>) do
      :nomatch when byte_size(buffer) <= @max_path_bytes ->
        {:ok, state, buffer}

      :nomatch ->
        {:halt, truncate(state, :path_limit)}

      {index, 1} ->
        path = binary_part(buffer, 0, index)
        rest = binary_part(buffer, index + 1, byte_size(buffer) - index - 1)

        state = inspect_discovered_path(path, root, relative_root, state, matcher)

        if state.stop? do
          {:halt, state}
        else
          consume_discovered_paths(rest, root, relative_root, state, matcher)
        end
    end
  end

  defp inspect_discovered_path(path, root, relative_root, state, matcher) do
    if path == root do
      state
    else
      relative_to_root = Path.relative_to(path, root)
      depth = length(Path.split(relative_to_root))

      if depth > state.limits.max_depth do
        truncate(state, :depth_limit)
      else
        state = account_entry(state)

        if state.stop? do
          state
        else
          relative =
            if relative_root == "",
              do: relative_to_root,
              else: Path.join(relative_root, relative_to_root)

          case File.lstat(path) do
            {:ok, %{type: :regular} = stat} ->
              if elixir_file?(path),
                do: scan_file(path, relative, stat, state, matcher),
                else: state

            {:ok, _directory_or_special} ->
              state

            {:error, _reason} ->
              %{state | skipped_unreadable_files: state.skipped_unreadable_files + 1}
          end
        end
      end
    end
  end

  defp close_discovery_port(port) when is_port(port) do
    if Port.info(port), do: Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp account_entry(state) do
    scanned_entries = state.scanned_entries + 1

    if scanned_entries > state.limits.max_entries do
      state |> Map.put(:scanned_entries, scanned_entries) |> truncate(:entry_limit)
    else
      %{state | scanned_entries: scanned_entries}
    end
  end

  defp scan_file(_path, _relative, _stat, %{stop?: true} = state, _matcher), do: state

  defp scan_file(path, relative, stat, state, matcher) do
    cond do
      state.scanned_files >= state.limits.max_files ->
        truncate(state, :file_limit)

      stat.size > state.limits.max_file_bytes ->
        state
        |> Map.update!(:skipped_large_files, &(&1 + 1))
        |> add_reason(:file_too_large)

      state.scanned_bytes + stat.size > state.limits.max_total_bytes ->
        truncate(state, :byte_limit)

      true ->
        case read_bounded(path, state.limits.max_file_bytes) do
          {:ok, _content, true} ->
            state
            |> Map.update!(:skipped_large_files, &(&1 + 1))
            |> add_reason(:file_too_large)

          {:ok, content, false} ->
            if state.scanned_bytes + byte_size(content) > state.limits.max_total_bytes do
              truncate(state, :byte_limit)
            else
              next = %{
                state
                | scanned_files: state.scanned_files + 1,
                  scanned_bytes: state.scanned_bytes + byte_size(content)
              }

              extract_file(content, relative, next, matcher)
            end

          {:error, reason} ->
            Logger.warning("ASTSearch: skipping #{relative}: read error #{inspect(reason)}")
            %{state | skipped_unreadable_files: state.skipped_unreadable_files + 1}
        end
    end
  end

  defp extract_file(content, relative, state, matcher) do
    remaining = max(state.limits.max_results - state.result_count, 0)

    case Extractor.extract_matching(content, relative, matcher,
           limit: remaining,
           entry_transform: &bound_symbol/1
         ) do
      {:ok, %{symbols: symbols, truncated?: truncated?}} ->
        next = retain_symbols(symbols, state)

        if truncated? and not next.stop?, do: truncate(next, :result_limit), else: next

      {:error, reason} ->
        Logger.warning("ASTSearch: skipping #{relative}: parse error #{inspect(reason)}")
        state
    end
  rescue
    error ->
      Logger.warning("ASTSearch: skipping #{relative}: #{Exception.message(error)}")
      state
  end

  defp metadata(state) do
    reasons = state.reasons |> MapSet.to_list() |> Enum.sort()

    %{
      results: Enum.reverse(state.results),
      truncated?: reasons != [],
      truncation_reasons: reasons,
      scanned_entries: min(state.scanned_entries, state.limits.max_entries),
      scanned_files: state.scanned_files,
      scanned_bytes: state.scanned_bytes,
      skipped_large_files: state.skipped_large_files,
      skipped_unreadable_files: state.skipped_unreadable_files,
      limits: state.limits
    }
  end

  defp truncate(state, reason), do: state |> add_reason(reason) |> Map.put(:stop?, true)
  defp add_reason(state, reason), do: %{state | reasons: MapSet.put(state.reasons, reason)}

  defp limits(opts) do
    %{
      max_results: bounded(opts[:limit], @default_limit, 1, @max_results),
      max_entries: bounded(opts[:max_entries], @default_max_entries, 1, @max_entries),
      max_files: bounded(opts[:max_files], @default_max_files, 1, @max_files),
      max_file_bytes:
        bounded(opts[:max_file_bytes], @default_max_file_bytes, 1, @hard_max_file_bytes),
      max_total_bytes:
        bounded(opts[:max_total_bytes], @default_max_total_bytes, 1, @hard_max_total_bytes),
      max_result_bytes:
        bounded(
          opts[:max_result_bytes],
          @default_max_result_bytes,
          1,
          @hard_max_result_bytes
        ),
      max_depth: bounded(opts[:max_depth], @default_max_depth, 1, @hard_max_depth)
    }
  end

  defp bounded(value, _default, minimum, maximum) when is_integer(value),
    do: value |> max(minimum) |> min(maximum)

  defp bounded(_value, default, _minimum, _maximum), do: default

  defp elixir_file?(name), do: Path.extname(name) in [".ex", ".exs"]

  defp read_bounded(path, maximum) do
    with {:ok, io} <- File.open(path, [:read, :binary]) do
      try do
        case IO.binread(io, maximum + 1) do
          :eof -> {:ok, "", false}
          {:error, reason} -> {:error, reason}
          content -> {:ok, content, byte_size(content) > maximum}
        end
      after
        File.close(io)
      end
    end
  end

  defp relative_directory(path, project_root) do
    case relative_path(path, project_root) do
      "." -> ""
      relative -> relative
    end
  end

  defp retain_symbols(symbols, state) do
    Enum.reduce_while(symbols, state, fn symbol, current ->
      bytes = :erlang.external_size(symbol)

      if current.result_bytes + bytes > current.limits.max_result_bytes do
        {:halt, truncate(current, :result_byte_limit)}
      else
        {:cont,
         %{
           current
           | results: [symbol | current.results],
             result_count: current.result_count + 1,
             result_bytes: current.result_bytes + bytes
         }}
      end
    end)
  end

  defp bound_symbol(symbol) do
    symbol
    |> Map.update(:file, "", &bounded_binary(&1, 4_096))
    |> Map.update(:name, "", &bounded_binary(&1, 512))
    |> Map.update(:module, nil, &bounded_optional_binary(&1, 512))
    |> Map.update(:code, "", &bounded_binary(&1, 4_096))
    |> Map.update(:metadata, %{}, &bounded_term(&1, 0))
  end

  defp bounded_term(_value, depth) when depth >= 4, do: "[depth truncated]"
  defp bounded_term(value, _depth) when is_binary(value), do: bounded_binary(value, 4_096)
  defp bounded_term(value, _depth) when is_atom(value) or is_number(value), do: value

  defp bounded_term(value, depth) when is_list(value) do
    value |> Enum.take(32) |> Enum.map(&bounded_term(&1, depth + 1))
  end

  defp bounded_term(value, depth) when is_map(value) do
    value
    |> Enum.take(32)
    |> Map.new(fn {key, nested} -> {key, bounded_term(nested, depth + 1)} end)
  end

  defp bounded_term(value, _depth), do: inspect(value, limit: 16, printable_limit: 1_024)

  defp bounded_optional_binary(nil, _maximum), do: nil
  defp bounded_optional_binary(value, maximum), do: bounded_binary(value, maximum)

  defp bounded_binary(value, maximum) when is_binary(value) do
    value
    |> binary_part(0, min(byte_size(value), maximum))
    |> String.replace_invalid()
    |> :binary.copy()
  end

  defp bounded_binary(value, maximum), do: value |> to_string() |> bounded_binary(maximum)

  # Relative path for display; absolute reusable API scopes outside the project
  # remain absolute. The model-facing gateway resolves and confines its scope.
  defp relative_path(file_path, project_root) do
    root = project_root |> to_string() |> String.trim_trailing("/")

    cond do
      file_path == root -> Path.basename(file_path)
      String.starts_with?(file_path, root <> "/") -> Path.relative_to(file_path, root)
      true -> file_path
    end
  end
end
