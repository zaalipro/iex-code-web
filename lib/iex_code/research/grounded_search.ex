defmodule IexCode.Research.GroundedSearch do
  @moduledoc """
  Entry point for model-native grounded answers.

  Unlike the federated `IexCode.Research.Search` plane, this API asks one model
  provider to run its hosted search tool and synthesize an answer with inline
  citations. The normalized output therefore contains an answer, citations,
  and provider-reported search calls—not ranked result rows and not a merged
  search-engine ranking.

  Providers are explicit. There is no automatic fallback because retrying a
  prompt with another model can duplicate search charges and changes the
  provenance of the synthesized answer.
  """

  alias IexCode.Research.GroundedSearch.Registry

  @doc "Runs one explicitly selected model-native grounded-search provider."
  def answer(provider, query, opts \\ [])

  def answer(provider, query, opts) when is_list(opts) do
    with {:ok, module} <- Registry.fetch(provider) do
      module.answer(query, opts)
    end
  end

  def answer(_provider, _query, _opts), do: {:error, {:configuration, :invalid_options}}

  defdelegate descriptors(), to: Registry
  defdelegate descriptor(provider), to: Registry
end
