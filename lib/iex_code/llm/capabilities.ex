defmodule IexCode.LLM.Capabilities do
  @moduledoc """
  Model capability detection and parameter compatibility matrix.
  Identifies whether models support native reasoning, extended thinking,
  omit temperature, require temperature 1.0, or use inline think tags.
  """

  @behaviour Access

  @type reasoning_type ::
          :reasoning_effort | :budget_tokens | :thinking_budget | :think_tags | :none
  @type provider_type :: :openai | :anthropic | :gemini | :local | :none

  defstruct [
    :provider,
    :model,
    :reasoning_supported,
    :reasoning_supported?,
    :type,
    :reasoning_type,
    :supports_temperature,
    :supports_temperature?,
    :requires_temperature_1_0?,
    :supports_extended_thinking?,
    :default_effort,
    :default_budget,
    :min_budget,
    :max_output_tokens,
    :tags
  ]

  # Access behaviour callbacks so callers can use either caps.field or caps[:field]
  @impl Access
  def fetch(struct, key), do: Map.fetch(struct, key)

  @impl Access
  def get_and_update(struct, key, fun), do: Map.get_and_update(struct, key, fun)

  @impl Access
  def pop(struct, key), do: Map.pop(struct, key)

  @openai_reasoning_prefixes ~w(o1 o3 o4)
  @anthropic_thinking_prefixes ~w(claude-3-7 claude-3.7 claude-4)
  @gemini_thinking_prefixes ~w(gemini-2.0-flash-thinking gemini-2.5-flash-thinking gemini-3.8-flash-thinking)
  @local_think_tag_patterns ~w(deepseek-r1 r1- qwen-qwq qwq)

  @doc """
  Detects reasoning and parameter capabilities for a given provider and model.
  """
  def detect(provider, model) when is_binary(model) do
    norm_provider = String.downcase(to_string(provider || "openai"))
    norm_model = String.downcase(String.trim(model))
    model_base = List.last(String.split(norm_model, "/"))

    cond do
      # OpenAI Reasoning Models (o1, o3, o3-mini, o4)
      (norm_provider == "openai" or norm_provider == "") and
          (matches_any_prefix?(model_base, @openai_reasoning_prefixes) or
             matches_any_prefix?(norm_model, @openai_reasoning_prefixes)) ->
        %__MODULE__{
          provider: "openai",
          model: model,
          reasoning_supported: true,
          reasoning_supported?: true,
          type: :openai,
          reasoning_type: :reasoning_effort,
          supports_temperature: false,
          supports_temperature?: false,
          requires_temperature_1_0?: false,
          supports_extended_thinking?: false,
          default_effort: "medium",
          default_budget: nil,
          min_budget: nil,
          max_output_tokens: 100_000,
          tags: [:reasoning, :coding, :fast]
        }

      # Anthropic Extended Thinking (Claude 3.7 Sonnet+)
      (norm_provider == "anthropic" or
         matches_any_prefix?(model_base, @anthropic_thinking_prefixes)) and
          (matches_any_prefix?(model_base, @anthropic_thinking_prefixes) or
             matches_any_prefix?(norm_model, @anthropic_thinking_prefixes) or
             String.contains?(norm_model, "claude-3-7") or
             String.contains?(norm_model, "claude-3.7")) ->
        %__MODULE__{
          provider: "anthropic",
          model: model,
          reasoning_supported: true,
          reasoning_supported?: true,
          type: :anthropic,
          reasoning_type: :budget_tokens,
          supports_temperature: true,
          supports_temperature?: true,
          requires_temperature_1_0?: true,
          supports_extended_thinking?: true,
          default_effort: "medium",
          default_budget: 4_096,
          min_budget: 1_024,
          max_output_tokens: 64_000,
          tags: [:extended_thinking, :coding, :analysis]
        }

      # Gemini Native Thinking Models
      (norm_provider in ["gemini", "google"] or String.contains?(norm_model, "thinking")) and
          (matches_any_prefix?(model_base, @gemini_thinking_prefixes) or
             String.contains?(norm_model, "thinking")) ->
        %__MODULE__{
          provider: norm_provider,
          model: model,
          reasoning_supported: true,
          reasoning_supported?: true,
          type: :gemini,
          reasoning_type: :thinking_budget,
          supports_temperature: true,
          supports_temperature?: true,
          requires_temperature_1_0?: false,
          supports_extended_thinking?: false,
          default_effort: "medium",
          default_budget: 4_096,
          min_budget: 1_024,
          max_output_tokens: 65_536,
          tags: [:thinking, :multimodal]
        }

      # Local & Open Reasoning Models (DeepSeek R1, QwQ)
      contains_any_pattern?(norm_model, @local_think_tag_patterns) ->
        %__MODULE__{
          provider: norm_provider,
          model: model,
          reasoning_supported: true,
          reasoning_supported?: true,
          type: :local,
          reasoning_type: :think_tags,
          supports_temperature: true,
          supports_temperature?: true,
          requires_temperature_1_0?: false,
          supports_extended_thinking?: false,
          default_effort: "medium",
          default_budget: 8_192,
          min_budget: 2_048,
          max_output_tokens: 32_768,
          tags: [:local_reasoning, :open_weights]
        }

      # Standard Models (GPT-4o, Claude 3.5 Sonnet, etc.)
      true ->
        default_standard_capabilities(norm_provider, model)
    end
  end

  def detect(provider, nil),
    do: default_standard_capabilities(to_string(provider || "openai"), "")

  @doc "Returns true if model supports reasoning or extended thinking."
  def reasoning_model?(provider, model) do
    detect(provider, model).reasoning_supported?
  end

  @doc "Returns true if model supports temperature configuration."
  def supports_temperature?(provider, model) do
    detect(provider, model).supports_temperature?
  end

  @doc "Returns true if model supports extended thinking (Anthropic Claude 3.7+)."
  def supports_extended_thinking?(provider, model) do
    detect(provider, model).supports_extended_thinking?
  end

  @doc "Returns default reasoning effort for model."
  def default_reasoning_effort(provider, model) do
    detect(provider, model).default_effort
  end

  @doc "Returns default thinking budget for model."
  def default_thinking_budget(provider, model) do
    detect(provider, model).default_budget
  end

  defp default_standard_capabilities(provider, model) do
    %__MODULE__{
      provider: provider,
      model: model,
      reasoning_supported: false,
      reasoning_supported?: false,
      type: :none,
      reasoning_type: :none,
      supports_temperature: true,
      supports_temperature?: true,
      requires_temperature_1_0?: false,
      supports_extended_thinking?: false,
      default_effort: "none",
      default_budget: nil,
      min_budget: nil,
      max_output_tokens: 4_096,
      tags: [:standard]
    }
  end

  defp matches_any_prefix?(model, prefixes) do
    Enum.any?(prefixes, fn prefix ->
      model == prefix or String.starts_with?(model, prefix <> "-") or
        String.starts_with?(model, prefix <> ".") or String.starts_with?(model, prefix <> "_")
    end)
  end

  defp contains_any_pattern?(model, patterns) do
    Enum.any?(patterns, &String.contains?(model, &1))
  end
end
