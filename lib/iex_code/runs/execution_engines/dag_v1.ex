defmodule IexCode.Runs.ExecutionEngines.DagV1 do
  @moduledoc """
  Available adapter for finite, immutable, dependency-aware workflows.

  Version one executes only handlers in the closed typed registry. The
  durable scheduler owns ready-node claims, bounded fan-out, append-only step
  attempts, leases, generation fencing, checkpoint receipts, retry backoff, and
  terminal recovery. The catalog includes bounded workspace reads and finite
  research workflows; unknown or future handler kinds remain fail-closed and
  existing `legacy_v1` runs are never reinterpreted as DAGs.
  """

  @behaviour IexCode.Runs.ExecutionEngine

  @impl true
  def id, do: "dag_v1"

  @impl true
  def available?, do: true

  @impl true
  def validate_manifest(_run_or_attrs, steps), do: IexCode.Runs.DagManifest.validate(steps)

  @impl true
  def prepare_manifest(_run_or_attrs, steps) do
    with {:ok, prepared} <- IexCode.Runs.DagManifest.persistence_steps(steps),
         {:ok, hash} <- IexCode.Runs.DagManifest.hash(steps) do
      {:ok, %{steps: prepared, manifest_hash: hash}}
    end
  end
end
