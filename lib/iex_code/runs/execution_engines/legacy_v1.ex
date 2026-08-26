defmodule IexCode.Runs.ExecutionEngines.LegacyV1 do
  @moduledoc """
  Compatibility owner for the existing fixed coding and research workflows.

  The dispatcher and typed executor continue to interpret these manifests. This
  adapter deliberately performs structural validation only; it does not infer
  generic readiness or scheduling semantics from dependency labels.
  """

  @behaviour IexCode.Runs.ExecutionEngine

  @max_steps 128

  @impl true
  def id, do: "legacy_v1"

  @impl true
  def available?, do: true

  @impl true
  def validate_manifest(_run_or_attrs, steps) when is_list(steps) do
    cond do
      steps == [] ->
        :ok

      length(steps) > @max_steps ->
        {:error, {:manifest_too_large, @max_steps}}

      Enum.any?(steps, &(not is_map(&1))) ->
        {:error, :invalid_manifest_step}

      Enum.any?(steps, &(blank?(value(&1, :key)) or blank?(value(&1, :kind)))) ->
        {:error, :invalid_manifest_step}

      duplicate_keys?(steps) ->
        {:error, :duplicate_step_key}

      true ->
        :ok
    end
  end

  def validate_manifest(_run_or_attrs, _steps), do: {:error, :invalid_manifest}

  @impl true
  def prepare_manifest(run_or_attrs, steps) do
    case validate_manifest(run_or_attrs, steps) do
      :ok -> {:ok, %{steps: steps, manifest_hash: nil}}
      {:error, _reason} = error -> error
    end
  end

  defp duplicate_keys?(steps) do
    keys = Enum.map(steps, &value(&1, :key))
    length(keys) != MapSet.size(MapSet.new(keys))
  end

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp blank?(value), do: not is_binary(value) or String.trim(value) == ""
end
