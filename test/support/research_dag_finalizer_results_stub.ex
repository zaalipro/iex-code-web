defmodule IexCode.TestResearchDagFinalizerResultsStub do
  @moduledoc false

  alias IexCode.Research.ResearchResult

  def get_by_run(_run), do: %ResearchResult{id: 42, status: "running"}

  def commit(result, markdown, opts) do
    send(self(), {:dag_finalizer_commit, result, markdown, opts})
    {:ok, %{result | status: "ready"}}
  end
end
