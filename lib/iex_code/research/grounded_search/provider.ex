defmodule IexCode.Research.GroundedSearch.Provider do
  @moduledoc """
  Strict contract for model-native hosted-search transports.

  Implementations make one bounded provider request (or a documented bounded
  continuation such as Anthropic `pause_turn`) and return a synthesized
  `GroundedAnswer`. They must check `opts[:cancelled?]` immediately before every
  request, return `{:error, :cancelled}` without issuing that request, never put
  credentials in an error, and reject responses that do not prove both hosted
  search activity and URL citations.

  These providers are independent from `IexCode.Research.Provider`: they do not
  return or pretend to return provider-ranked search results.
  """

  alias IexCode.Research.GroundedSearch.GroundedAnswer

  @type error ::
          :cancelled
          | {:configuration, term()}
          | {:http_error, pos_integer(), term()}
          | {:provider_error, term()}
          | {:incomplete, term()}
          | {:invalid_response, term()}
          | {:ungrounded_response, :no_search_calls | :no_citations}

  @callback id() :: atom()
  @callback answer(String.t(), keyword()) :: {:ok, GroundedAnswer.t()} | {:error, error()}
end
