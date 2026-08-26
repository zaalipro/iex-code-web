defmodule IexCode.Runs.ExecutionEngine do
  @moduledoc """
  Contract for selecting a persisted run execution engine.

  Existing coding and research manifests are descriptive fixed workflows. They
  are owned by `legacy_v1` and must never be reinterpreted as generic DAGs merely
  because their steps contain `depends_on` values. The dependency-aware scheduler
  is selected only through a run persisted with `execution_engine: "dag_v1"` and
  accepts only kinds in its closed typed registry.
  """

  alias IexCode.Runs.Run

  @type manifest :: [map()]
  @type validation_error :: term()

  @callback id() :: String.t()
  @callback validate_manifest(map() | Run.t(), manifest()) ::
              :ok | {:error, validation_error()}
  @callback prepare_manifest(map() | Run.t(), manifest()) ::
              {:ok, %{steps: manifest(), manifest_hash: String.t() | nil}}
              | {:error, validation_error()}
  @callback available?() :: boolean()

  @engines %{
    "legacy_v1" => IexCode.Runs.ExecutionEngines.LegacyV1,
    "dag_v1" => IexCode.Runs.ExecutionEngines.DagV1
  }

  @doc "Returns the fixed adapter module for a persisted engine identifier."
  @spec fetch(String.t() | atom()) :: {:ok, module()} | :error
  def fetch(engine) when is_atom(engine), do: fetch(Atom.to_string(engine))
  def fetch(engine) when is_binary(engine), do: Map.fetch(@engines, engine)
  def fetch(_engine), do: :error

  @doc "Validates a manifest through its explicitly selected engine."
  @spec validate_manifest(map() | Run.t(), manifest()) ::
          :ok | {:error, validation_error()}
  def validate_manifest(run_or_attrs, steps) when is_list(steps) do
    engine = engine_id(run_or_attrs)

    with {:ok, module} <- fetch(engine),
         true <- module.available?() do
      module.validate_manifest(run_or_attrs, steps)
    else
      :error -> {:error, {:unknown_execution_engine, engine}}
      false -> {:error, {:execution_engine_unavailable, engine}}
    end
  end

  def validate_manifest(_run_or_attrs, _steps), do: {:error, :invalid_manifest}

  @doc "Canonicalizes a manifest for durable storage through its selected engine."
  def prepare_manifest(run_or_attrs, steps) when is_list(steps) do
    engine = engine_id(run_or_attrs)

    case fetch(engine) do
      {:ok, module} -> module.prepare_manifest(run_or_attrs, steps)
      :error -> {:error, {:unknown_execution_engine, engine}}
    end
  end

  def prepare_manifest(_run_or_attrs, _steps), do: {:error, :invalid_manifest}

  @doc "Lists stable engine identifiers and whether they can currently execute."
  @spec descriptors() :: [%{id: String.t(), available: boolean()}]
  def descriptors do
    Enum.map(@engines, fn {id, module} -> %{id: id, available: module.available?()} end)
    |> Enum.sort_by(& &1.id)
  end

  @doc "Lists the persisted engine identifiers that are currently safe to dispatch."
  @spec available_ids() :: [String.t()]
  def available_ids do
    @engines
    |> Enum.filter(fn {_id, module} -> module.available?() end)
    |> Enum.map(fn {id, _module} -> id end)
    |> Enum.sort()
  end

  defp engine_id(%Run{execution_engine: engine}), do: engine || "legacy_v1"

  defp engine_id(attrs) when is_map(attrs) do
    Map.get(attrs, :execution_engine) || Map.get(attrs, "execution_engine") || "legacy_v1"
  end

  defp engine_id(_other), do: "legacy_v1"
end
