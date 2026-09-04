defmodule IexCode.Workflows.VariableInterpolator do
  @moduledoc """
  Interpolates user input variables, project metadata, and step outputs
  into step parameter configurations with type preservation and recursive resolution.
  """

  @var_regex ~r/\{\{\s*([a-zA-Z0-9_.]+)\s*\}\}/
  @exact_var_regex ~r/^\s*\{\{\s*([a-zA-Z0-9_.]+)\s*\}\}\s*$/

  @doc """
  Recursively interpolates placeholders in `target` using values from `context`.

  When `target` is a single variable expression like `"{{files}}"`, its native
  type (e.g. list, map, integer) is preserved.

  Returns `{:ok, interpolated}` or `{:error, reason}`.
  """
  @spec interpolate(term(), map()) :: {:ok, term()} | {:error, term()}
  def interpolate(target, context) when is_map(context) do
    try do
      {:ok, do_interpolate(target, context)}
    rescue
      e -> {:error, {:interpolation_failed, Exception.message(e)}}
    end
  end

  def interpolate(target, _), do: {:ok, target}

  @doc """
  Same as `interpolate/2`, but raises on failure or returns the result directly.
  """
  @spec interpolate!(term(), map()) :: term()
  def interpolate!(target, context) when is_map(context) do
    case interpolate(target, context) do
      {:ok, res} -> res
      {:error, reason} -> raise "Variable interpolation failed: #{inspect(reason)}"
    end
  end

  @doc """
  Finds all variable references in `target` that cannot be resolved from `context`.
  Returns a list of missing variable names.
  """
  @spec missing_variables(term(), map()) :: list(String.t())
  def missing_variables(target, context) when is_map(context) do
    refs = extract_variable_references(target)

    Enum.filter(refs, fn ref ->
      case resolve_path(ref, context) do
        nil -> true
        _ -> false
      end
    end)
    |> Enum.uniq()
  end

  @doc """
  Extracts all variable reference strings from a data structure.
  """
  @spec extract_variable_references(term()) :: list(String.t())
  def extract_variable_references(data) when is_binary(data) do
    Regex.scan(@var_regex, data, capture: :all_but_first)
    |> List.flatten()
  end

  def extract_variable_references(data) when is_map(data) and not is_struct(data) do
    data
    |> Map.values()
    |> Enum.flat_map(&extract_variable_references/1)
    |> Enum.uniq()
  end

  def extract_variable_references(data) when is_list(data) do
    data
    |> Enum.flat_map(&extract_variable_references/1)
    |> Enum.uniq()
  end

  def extract_variable_references(_), do: []

  # Internal recursive interpolation

  defp do_interpolate(str, context) when is_binary(str) do
    case Regex.run(@exact_var_regex, str) do
      [_, var_path] ->
        case resolve_path(var_path, context) do
          nil -> str
          val -> val
        end

      nil ->
        Regex.replace(@var_regex, str, fn _, var_path ->
          case resolve_path(var_path, context) do
            nil -> "{{#{var_path}}}"
            val -> to_string_repr(val)
          end
        end)
    end
  end

  defp do_interpolate(map, context) when is_map(map) and not is_struct(map) do
    Map.new(map, fn {k, v} ->
      interpolated_key =
        if is_binary(k) do
          case do_interpolate(k, context) do
            str when is_binary(str) -> str
            other -> to_string_repr(other)
          end
        else
          k
        end

      {interpolated_key, do_interpolate(v, context)}
    end)
  end

  defp do_interpolate(list, context) when is_list(list) do
    Enum.map(list, &do_interpolate(&1, context))
  end

  defp do_interpolate(other, _context), do: other

  @doc """
  Resolves a dotted variable path like "feature_name" or "steps.research.output.report"
  within context.
  """
  @spec resolve_path(String.t(), map()) :: term()
  def resolve_path(path, context) when is_binary(path) and is_map(context) do
    keys = String.split(path, ".")

    case do_resolve(keys, context) do
      nil ->
        # Fallback: if not found at root, check inside "inputs"
        case keys do
          ["inputs" | _] ->
            nil

          _ ->
            inputs = fetch_key(context, "inputs")
            if is_map(inputs), do: do_resolve(keys, inputs), else: nil
        end

      val ->
        val
    end
  end

  defp do_resolve([], current), do: current

  defp do_resolve([key | rest], current) when is_map(current) do
    case fetch_key(current, key) do
      nil -> nil
      val -> do_resolve(rest, val)
    end
  end

  defp do_resolve(_keys, _current), do: nil

  defp fetch_key(map, key) when is_map(map) and is_binary(key) do
    case Map.get(map, key) do
      nil ->
        # Try atom key safely if it already exists
        try do
          atom_key = String.to_existing_atom(key)
          Map.get(map, atom_key)
        rescue
          ArgumentError -> nil
        end

      val ->
        val
    end
  end

  defp fetch_key(_map, _key), do: nil

  defp to_string_repr(nil), do: ""
  defp to_string_repr(val) when is_binary(val), do: val

  defp to_string_repr(val) when is_number(val) or is_boolean(val) or is_atom(val),
    do: to_string(val)

  defp to_string_repr(val) when is_list(val) or is_map(val) do
    case Jason.encode(val) do
      {:ok, json} -> json
      _ -> inspect(val)
    end
  end

  defp to_string_repr(other), do: inspect(other)
end
