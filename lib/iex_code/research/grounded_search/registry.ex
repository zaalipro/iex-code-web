defmodule IexCode.Research.GroundedSearch.Registry do
  @moduledoc """
  Explicit registry for model-native hosted-search transports.

  Descriptors state protocol and lifecycle limitations. Unsupported entries
  remain discoverable but cannot be invoked, preventing callers from confusing
  a marketing capability name with an implemented, bounded transport contract.
  """

  @order [:openai_responses, :anthropic_messages, :gemini_interactions, :azure_foundry]
  @descriptors %{
    openai_responses: %{
      id: :openai_responses,
      module: IexCode.Research.GroundedSearch.Providers.OpenAIResponses,
      status: :supported,
      lifecycle: :active,
      protocol: :responses_web_search,
      origin: "https://api.openai.com",
      capabilities: [:grounded_answer, :url_citations, :search_call_trace]
    },
    anthropic_messages: %{
      id: :anthropic_messages,
      module: IexCode.Research.GroundedSearch.Providers.AnthropicMessages,
      status: :supported,
      lifecycle: :active,
      protocol: :messages_web_search,
      origin: "https://api.anthropic.com",
      capabilities: [:grounded_answer, :url_citations, :search_call_trace, :bounded_pause_turn],
      default_tool_version: "web_search_20260318",
      supported_tool_versions: [
        "web_search_20250305",
        "web_search_20260209",
        "web_search_20260318"
      ],
      limitation:
        "Direct hosted search is selected intentionally; dynamic filtering through hidden code execution is not enabled by this adapter."
    },
    gemini_interactions: %{
      id: :gemini_interactions,
      module: IexCode.Research.GroundedSearch.Providers.GeminiInteractions,
      status: :supported,
      lifecycle: :beta,
      protocol: :interactions_google_search,
      origin: "https://generativelanguage.googleapis.com",
      capabilities: [:grounded_answer, :url_citations, :search_call_trace],
      limitation: "Google documents the Interactions API as beta and revisions can be breaking."
    },
    azure_foundry: %{
      id: :azure_foundry,
      module: nil,
      status: :unsupported,
      lifecycle: :active,
      protocol: :foundry_web_grounding,
      origin: nil,
      capabilities: [],
      limitation:
        "Foundry grounding currently requires project-specific endpoints, Entra or project credentials, and tool/connection resources; this plane has no accurate single official-origin API-key contract for it."
    }
  }

  def descriptors, do: Enum.map(@order, &Map.fetch!(@descriptors, &1))

  def descriptor(provider) do
    with {:ok, id} <- normalize(provider), do: Map.fetch(@descriptors, id)
  end

  def fetch(provider) do
    case descriptor(provider) do
      {:ok, %{status: :supported, module: module}} when is_atom(module) ->
        {:ok, module}

      {:ok, %{status: :unsupported, limitation: reason}} ->
        {:error, {:unsupported_provider, reason}}

      :error ->
        {:error, {:unknown_provider, provider}}
    end
  end

  defp normalize(provider) when is_atom(provider) do
    if provider in @order, do: {:ok, provider}, else: :error
  end

  defp normalize(provider) when is_binary(provider) do
    Enum.find_value(@order, :error, fn id ->
      if Atom.to_string(id) == provider, do: {:ok, id}
    end)
  end

  defp normalize(_provider), do: :error
end
