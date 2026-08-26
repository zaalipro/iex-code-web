defmodule IexCode.Runs.DagManifest do
  @moduledoc "Immutable canonical graph contract for the closed-registry `dag_v1` engine."

  alias IexCode.Runs.{DagPayload, DagStepRegistry}

  @max_steps 128
  @max_edges 512
  @max_dependencies 32
  @max_attempts 5
  @max_graph_depth 32
  @key_format ~r/^[A-Za-z0-9][A-Za-z0-9._:-]*$/
  @allowed_fields ~w(key kind title depends_on params max_attempts)

  @type step :: map()

  def validate(steps) do
    case normalize(steps) do
      {:ok, _normalized} -> :ok
      {:error, _reason} = error -> error
    end
  end

  def normalize(steps) when is_list(steps) do
    cond do
      steps == [] -> {:error, :empty_dag_manifest}
      length(steps) > @max_steps -> {:error, {:manifest_too_large, @max_steps}}
      true -> do_normalize(steps)
    end
  end

  def normalize(_steps), do: {:error, :invalid_dag_manifest}

  def canonical(steps) do
    with {:ok, normalized} <- normalize(steps) do
      {:ok,
       Enum.map(normalized, fn step ->
         descriptor = DagStepRegistry.descriptor!(step.kind)

         %{
           "key" => step.key,
           "kind" => step.kind,
           "title" => step.title,
           "depends_on" => step.depends_on,
           "params" => step.params,
           "max_attempts" => step.max_attempts,
           "handler" => %{
             "version" => descriptor.version,
             "effect_class" => Atom.to_string(descriptor.effect_class),
             "replay_policy" => Atom.to_string(descriptor.replay_policy),
             "resource_contract" => descriptor.resource_contract,
             "checkpoint_version" => descriptor.checkpoint_version,
             "max_output_bytes" => descriptor.max_output_bytes,
             "default_timeout_ms" => descriptor.default_timeout_ms
           }
         }
       end)}
    end
  end

  def hash(steps) do
    with {:ok, canonical} <- canonical(steps),
         {:ok, encoded} <- DagPayload.canonical_json(canonical) do
      {:ok,
       :crypto.hash(:sha256, "iex-code/dag-manifest/v1\0" <> encoded)
       |> Base.encode16(case: :lower)}
    end
  end

  def persistence_steps(steps) do
    with {:ok, normalized} <- normalize(steps) do
      {:ok,
       Enum.map(normalized, fn step ->
         descriptor = DagStepRegistry.descriptor!(step.kind)

         Map.merge(step, %{
           handler_version: descriptor.version,
           effect_class: Atom.to_string(descriptor.effect_class),
           replay_policy: Atom.to_string(descriptor.replay_policy),
           resource_spec: %{"contract" => descriptor.resource_contract},
           timeout_ms: descriptor.default_timeout_ms
         })
       end)}
    end
  end

  def kinds, do: DagStepRegistry.kinds()

  defp do_normalize(steps) do
    with {:ok, normalized} <- normalize_steps(steps),
         :ok <- validate_unique_keys(normalized),
         :ok <- validate_dependencies(normalized),
         :ok <- validate_acyclic(normalized) do
      normalized = Enum.sort_by(normalized, & &1.key)

      {:ok,
       normalized
       |> Enum.with_index()
       |> Enum.map(fn {step, position} ->
         step
         |> Map.put(:position, position)
         |> Map.put(:status, if(step.depends_on == [], do: "ready", else: "pending"))
       end)}
    end
  end

  defp normalize_steps(steps) do
    steps
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {step, input_position}, {:ok, normalized} ->
      case normalize_step(step) do
        {:ok, value} -> {:cont, {:ok, [value | normalized]}}
        {:error, reason} -> {:halt, {:error, {:invalid_dag_step, input_position, reason}}}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_step(step) when is_map(step) and not is_struct(step) do
    with :ok <- validate_known_fields(step),
         {:ok, key} <- required_string(step, :key, 160),
         true <- Regex.match?(@key_format, key) or {:error, :invalid_key},
         {:ok, kind} <- required_string(step, :kind, 80),
         true <- kind in kinds() or {:error, {:unsupported_kind, kind}},
         {:ok, title} <- required_string(step, :title, 500),
         {:ok, dependencies} <- dependencies(step),
         {:ok, params} <- params(step),
         {:ok, max_attempts} <- max_attempts(step),
         :ok <- DagStepRegistry.validate_params(kind, params, dependencies) do
      {:ok,
       %{
         key: key,
         kind: kind,
         title: title,
         depends_on: Enum.sort(dependencies),
         params: params,
         max_attempts: max_attempts
       }}
    else
      false -> {:error, :invalid_step}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_step(_step), do: {:error, :not_a_plain_map}

  defp validate_known_fields(step) do
    aliases =
      @allowed_fields
      |> Enum.filter(fn name ->
        Map.has_key?(step, name) and Map.has_key?(step, known_atom(name))
      end)

    unknown =
      Map.keys(step)
      |> Enum.reject(fn key ->
        (is_atom(key) and Atom.to_string(key) in @allowed_fields) or
          (is_binary(key) and key in @allowed_fields)
      end)

    cond do
      aliases != [] -> {:error, {:duplicate_field_aliases, aliases}}
      unknown != [] -> {:error, {:unknown_fields, Enum.map(unknown, &inspect/1)}}
      true -> :ok
    end
  end

  defp required_string(step, field, maximum) do
    case value(step, field) do
      value when is_binary(value) ->
        value = String.trim(value)

        cond do
          byte_size(value) not in 1..maximum -> {:error, {field, :invalid}}
          not String.valid?(value) -> {:error, {field, :invalid_utf8}}
          true -> {:ok, value}
        end

      _value ->
        {:error, {field, :required}}
    end
  end

  defp dependencies(step) do
    case value(step, :depends_on, []) do
      values when is_list(values) and length(values) <= @max_dependencies ->
        cond do
          Enum.any?(values, &(not is_binary(&1) or byte_size(&1) not in 1..160)) ->
            {:error, :invalid_dependencies}

          Enum.any?(values, &(not String.valid?(&1))) ->
            {:error, :invalid_dependency_utf8}

          length(values) != MapSet.size(MapSet.new(values)) ->
            {:error, :duplicate_dependencies}

          true ->
            {:ok, values}
        end

      _values ->
        {:error, :invalid_dependencies}
    end
  end

  defp params(step) do
    params = value(step, :params, %{})

    case DagPayload.validate(params, max_bytes: 64_000) do
      {:ok, validated} when is_map(validated) -> {:ok, validated}
      {:ok, _validated} -> {:error, :invalid_params}
      {:error, _reason} = error -> error
    end
  end

  defp max_attempts(step) do
    case value(step, :max_attempts, 1) do
      attempts when is_integer(attempts) and attempts in 1..@max_attempts -> {:ok, attempts}
      _attempts -> {:error, {:invalid_max_attempts, @max_attempts}}
    end
  end

  defp validate_unique_keys(steps) do
    keys = Enum.map(steps, & &1.key)
    if length(keys) == MapSet.size(MapSet.new(keys)), do: :ok, else: {:error, :duplicate_step_key}
  end

  defp validate_dependencies(steps) do
    keys = MapSet.new(Enum.map(steps, & &1.key))
    edge_count = Enum.sum(Enum.map(steps, &length(&1.depends_on)))

    if edge_count > @max_edges do
      {:error, {:manifest_has_too_many_edges, @max_edges}}
    else
      Enum.reduce_while(steps, :ok, fn step, :ok ->
        missing = Enum.reject(step.depends_on, &MapSet.member?(keys, &1))

        cond do
          step.key in step.depends_on -> {:halt, {:error, {:self_dependency, step.key}}}
          missing != [] -> {:halt, {:error, {:missing_dependencies, step.key, missing}}}
          true -> {:cont, :ok}
        end
      end)
    end
  end

  defp validate_acyclic(steps) do
    indegree = Map.new(steps, &{&1.key, length(&1.depends_on)})

    dependants =
      Enum.reduce(steps, %{}, fn step, acc ->
        Enum.reduce(step.depends_on, acc, fn dependency, nested ->
          Map.update(nested, dependency, [step.key], &[step.key | &1])
        end)
      end)

    queue = indegree |> Enum.filter(&(elem(&1, 1) == 0)) |> Enum.map(&elem(&1, 0)) |> Enum.sort()
    depths = Map.new(queue, &{&1, 1})
    {count, depth} = kahn(queue, indegree, dependants, depths, 0, 0)

    cond do
      count != length(steps) -> {:error, :cyclic_dependencies}
      depth > @max_graph_depth -> {:error, {:graph_too_deep, @max_graph_depth}}
      true -> :ok
    end
  end

  defp kahn([], _indegree, _dependants, _depths, count, depth), do: {count, depth}

  defp kahn([key | rest], indegree, dependants, depths, count, maximum_depth) do
    current_depth = Map.fetch!(depths, key)

    {indegree, depths, ready} =
      dependants
      |> Map.get(key, [])
      |> Enum.sort()
      |> Enum.reduce({indegree, depths, []}, fn dependant, {degrees, node_depths, ready} ->
        degree = Map.fetch!(degrees, dependant) - 1

        node_depths =
          Map.update(node_depths, dependant, current_depth + 1, &max(&1, current_depth + 1))

        {Map.put(degrees, dependant, degree), node_depths,
         if(degree == 0, do: [dependant | ready], else: ready)}
      end)

    kahn(
      Enum.sort(rest ++ ready),
      indegree,
      dependants,
      depths,
      count + 1,
      max(maximum_depth, current_depth)
    )
  end

  defp known_atom("key"), do: :key
  defp known_atom("kind"), do: :kind
  defp known_atom("title"), do: :title
  defp known_atom("depends_on"), do: :depends_on
  defp known_atom("params"), do: :params
  defp known_atom("max_attempts"), do: :max_attempts

  defp value(map, key, default \\ nil),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
