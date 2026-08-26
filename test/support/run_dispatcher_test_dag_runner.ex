defmodule IexCode.RunDispatcherTestDagRunner do
  @moduledoc false

  alias IexCode.Runs.DagScheduler

  def run(run, opts) do
    owner = Keyword.fetch!(opts, :lease_owner)
    generation = Keyword.fetch!(opts, :lease_generation)

    with {:ok, claim} <-
           DagScheduler.claim_ready(run, owner, generation,
             lease_ms: Keyword.fetch!(opts, :lease_ms)
           ) do
      receiver = Process.whereis(IexCode.RunDispatcherTestReceiver)
      if receiver, do: send(receiver, {:dag_step_started, claim.step.key, self()})
      receive do: (:finish_fake_dag -> {:ok, run})
    end
  end
end
