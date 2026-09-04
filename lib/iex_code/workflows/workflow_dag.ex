defmodule IexCode.Workflows.WorkflowDag do
  @moduledoc """
  Topological validator, cycle detector, and layering engine for workflow DAGs.
  Uses Kahn's algorithm for cycle detection and supports topological sort,
  parallel layer computation, and ready-step resolution.
  """

  @allowed_kinds ~w(deep_research swarm_code_gen test_verification security_audit git_commit)
  @allowed_reasoning ~w(none low medium high thinking_budget)
  @allowed_safety ~w(full_auto prompt_dangerous read_only)
  @key_format ~r/^[A-Za-z0-9][A-Za-z0-9._:-]*$/
  @max_steps 64

  @doc "Returns allowed step kinds."
  def allowed_kinds, do: @allowed_kinds

  @doc "Returns allowed reasoning effort levels."
  def allowed_reasoning, do: @allowed_reasoning

  @doc "Returns allowed safety policies."
  def allowed_safety, do: @allowed_safety

  @spec validate(list(map()), list(map())) :: :ok | {:error, term()}
  def validate(steps, declared_variables \\ [])

  def validate(steps, declared_variables) when is_list(steps) do
    cond do
      steps == [] ->
        {:error, :empty_steps}

      length(steps) > @max_steps ->
        {:error, :too_many_steps}

      true ->
        with :ok <- validate_step_shapes(steps),
             :ok <- validate_unique_keys(steps),
             :ok <- validate_dependencies_exist(steps),
             :ok <- validate_acyclic(steps),
             :ok <- validate_step_configs(steps),
             :ok <- validate_variable_references(steps, declared_variables) do
          :ok
        end
    end
  end

  def validate(_steps, _vars), do: {:error, :invalid_steps_list}

  @doc """
  Computes the topological sorting of step keys.
  Returns `{:ok, [key1, key2, ...]}` or `{:error, :cyclic_dependencies}`.
  """
  @spec topological_sort(list(map())) :: {:ok, list(String.t())} | {:error, term()}
  def topological_sort(steps) when is_list(steps) do
    with :ok <- validate_step_shapes(steps),
         :ok <- validate_unique_keys(steps),
         :ok <- validate_dependencies_exist(steps) do
      indegree = build_indegree_map(steps)
      dependants = build_dependants_map(steps)

      queue =
        indegree
        |> Enum.filter(fn {_, deg} -> deg == 0 end)
        |> Enum.map(&elem(&1, 0))
        |> Enum.sort()

      case kahn_sort(queue, indegree, dependants, []) do
        sorted when length(sorted) == length(steps) ->
          {:ok, sorted}

        _ ->
          {:error, :cyclic_dependencies}
      end
    end
  end

  @doc """
  Groups steps into topological execution layers.
  Each layer is a list of steps that can be run concurrently once preceding layers finish.
  """
  @spec topological_layers(list(map())) :: {:ok, list(list(map()))} | {:error, term()}
  def topological_layers(steps) when is_list(steps) do
    with {:ok, _sorted_keys} <- topological_sort(steps) do
      step_map = Map.new(steps, fn s -> {step_key(s), s} end)

      # Compute longest distance from any root to each node
      levels = compute_node_levels(steps)

      max_level =
        if map_size(levels) == 0 do
          0
        else
          levels |> Map.values() |> Enum.max()
        end

      layers =
        for lvl <- 0..max_level do
          levels
          |> Enum.filter(fn {_, l} -> l == lvl end)
          |> Enum.map(fn {k, _} -> Map.fetch!(step_map, k) end)
        end

      {:ok, layers}
    end
  end

  @doc """
  Determines which steps are ready to run given a set of completed step keys.
  A step is ready if:
  1. It is not completed.
  2. It is not failed.
  3. All its dependencies are in `completed_keys`.
  """
  @spec ready_steps(list(map()), list(String.t()) | MapSet.t(), list(String.t()) | MapSet.t()) ::
          list(map())
  def ready_steps(steps, completed_keys, failed_keys \\ []) do
    completed_set = MapSet.new(completed_keys)
    failed_set = MapSet.new(failed_keys)

    Enum.filter(steps, fn s ->
      k = step_key(s)
      deps = step_deps(s)

      not MapSet.member?(completed_set, k) and
        not MapSet.member?(failed_set, k) and
        Enum.all?(deps, &MapSet.member?(completed_set, &1))
    end)
  end

  @doc "Extracts all `{{variable}}` references recursively from strings, maps, or lists."
  def extract_variable_references(data) when is_binary(data) do
    Regex.scan(~r/\{\{\s*([a-zA-Z0-9_.]+)\s*\}\}/, data, capture: :all_but_first)
    |> List.flatten()
  end

  def extract_variable_references(data) when is_map(data) do
    data |> Map.values() |> Enum.flat_map(&extract_variable_references/1)
  end

  def extract_variable_references(data) when is_list(data) do
    Enum.flat_map(data, &extract_variable_references/1)
  end

  def extract_variable_references(_), do: []

  # Internal helper to extract key regardless of string or atom keys
  def step_key(step) do
    to_string(Map.get(step, "key") || Map.get(step, :key) || "")
  end

  def step_deps(step) do
    deps = Map.get(step, "depends_on") || Map.get(step, :depends_on) || []
    Enum.map(deps, &to_string/1)
  end

  # Validations

  defp validate_step_shapes(steps) do
    Enum.reduce_while(steps, :ok, fn step, :ok ->
      key = step_key(step)
      kind = to_string(Map.get(step, "kind") || Map.get(step, :kind) || "")

      cond do
        key == "" or not Regex.match?(@key_format, key) ->
          {:halt, {:error, {:invalid_step_key, key}}}

        kind not in @allowed_kinds ->
          {:halt, {:error, {:unsupported_kind, kind}}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp validate_unique_keys(steps) do
    keys = Enum.map(steps, &step_key/1)

    if length(keys) == MapSet.size(MapSet.new(keys)) do
      :ok
    else
      {:error, :duplicate_step_keys}
    end
  end

  defp validate_dependencies_exist(steps) do
    keys = MapSet.new(Enum.map(steps, &step_key/1))

    Enum.reduce_while(steps, :ok, fn step, :ok ->
      key = step_key(step)
      deps = step_deps(step)
      missing = Enum.reject(deps, &MapSet.member?(keys, &1))

      cond do
        key in deps ->
          {:halt, {:error, {:self_dependency, key}}}

        missing != [] ->
          {:halt, {:error, {:missing_dependencies, key, missing}}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp validate_acyclic(steps) do
    case topological_sort(steps) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_step_configs(steps) do
    Enum.reduce_while(steps, :ok, fn step, :ok ->
      model_config = Map.get(step, "model_config") || Map.get(step, :model_config) || %{}
      safety = Map.get(step, "safety_policy") || Map.get(step, :safety_policy)

      reasoning =
        Map.get(model_config, "reasoning_effort") || Map.get(model_config, :reasoning_effort)

      cond do
        safety != nil and to_string(safety) not in @allowed_safety ->
          {:halt, {:error, {:invalid_safety_policy, safety}}}

        reasoning != nil and to_string(reasoning) not in @allowed_reasoning ->
          {:halt, {:error, {:invalid_reasoning_effort, reasoning}}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp validate_variable_references(steps, declared_variables) do
    declared_names =
      declared_variables
      |> Enum.map(fn v ->
        to_string(Map.get(v, "name") || Map.get(v, :name) || "")
      end)
      |> Enum.reject(&(&1 == ""))
      |> MapSet.new()

    builtin_names = MapSet.new(~w(project.name project.root_path session.id inputs))

    Enum.reduce_while(steps, :ok, fn step, :ok ->
      deps = MapSet.new(step_deps(step))
      refs = extract_variable_references(step)

      invalid =
        Enum.reject(refs, fn ref ->
          cond do
            MapSet.member?(declared_names, ref) ->
              true

            MapSet.member?(builtin_names, ref) ->
              true

            String.starts_with?(ref, "inputs.") ->
              var = String.replace_prefix(ref, "inputs.", "")
              MapSet.member?(declared_names, var)

            String.starts_with?(ref, "steps.") ->
              # Form: steps.<step_key>.output.<field>
              case String.split(ref, ".") do
                ["steps", step_ref | _rest] ->
                  MapSet.member?(deps, step_ref)

                _ ->
                  false
              end

            true ->
              false
          end
        end)

      if invalid == [] do
        {:cont, :ok}
      else
        {:halt, {:error, {:invalid_variable_references, step_key(step), invalid}}}
      end
    end)
  end

  # Kahn sort algorithm implementation
  defp build_indegree_map(steps) do
    Map.new(steps, fn s ->
      {step_key(s), length(step_deps(s))}
    end)
  end

  defp build_dependants_map(steps) do
    Enum.reduce(steps, %{}, fn s, acc ->
      k = step_key(s)
      deps = step_deps(s)

      Enum.reduce(deps, acc, fn dep, nested ->
        Map.update(nested, dep, [k], &[k | &1])
      end)
    end)
  end

  defp kahn_sort([], _indegree, _dependants, acc), do: Enum.reverse(acc)

  defp kahn_sort([key | rest], indegree, dependants, acc) do
    dependants_for_key = Map.get(dependants, key, [])

    {new_indegree, newly_ready} =
      Enum.reduce(dependants_for_key, {indegree, []}, fn dep, {deg, rdy} ->
        current = Map.fetch!(deg, dep)
        new_deg = current - 1
        deg = Map.put(deg, dep, new_deg)

        if new_deg == 0 do
          {deg, [dep | rdy]}
        else
          {deg, rdy}
        end
      end)

    # Maintain deterministic order
    next_queue = rest ++ Enum.sort(newly_ready)
    kahn_sort(next_queue, new_indegree, dependants, [key | acc])
  end

  defp compute_node_levels(steps) do
    # Map each node to its longest path from roots (in-degree 0)
    step_map = Map.new(steps, fn s -> {step_key(s), s} end)
    {:ok, sorted_keys} = topological_sort(steps)

    Enum.reduce(sorted_keys, %{}, fn key, acc ->
      step = Map.fetch!(step_map, key)
      deps = step_deps(step)

      level =
        if deps == [] do
          0
        else
          max_dep_level = deps |> Enum.map(&Map.get(acc, &1, 0)) |> Enum.max()
          max_dep_level + 1
        end

      Map.put(acc, key, level)
    end)
  end
end
