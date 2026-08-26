defmodule IexCode.Research.GroundedSearch.GroundedAnswer do
  @moduledoc """
  A model-synthesized answer whose citations and hosted-search calls were
  reported by the model provider.

  This is deliberately not a ranked search-result page. `citations` identify
  passages in `answer`; `search_calls` describe hosted tool activity. Neither
  collection is assigned a relevance rank by IexCode.
  """

  @enforce_keys [:answer, :citations, :search_calls, :usage, :provider, :metadata]
  defstruct [:answer, :citations, :search_calls, :usage, :provider, :metadata]

  @type citation :: %{
          required(:url) => String.t(),
          optional(:title) => String.t() | nil,
          optional(:start_index) => non_neg_integer() | nil,
          optional(:end_index) => non_neg_integer() | nil,
          optional(:cited_text) => String.t() | nil,
          optional(:metadata) => map()
        }

  @type search_call :: %{
          optional(:id) => String.t() | nil,
          required(:queries) => [String.t()],
          optional(:status) => String.t() | nil,
          optional(:metadata) => map()
        }

  @type t :: %__MODULE__{
          answer: String.t(),
          citations: [citation()],
          search_calls: [search_call()],
          usage: map(),
          provider: atom(),
          metadata: map()
        }
end
