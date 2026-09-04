defmodule IexCode.Swarm.RoleSpec do
  @moduledoc """
  Role specification and capability profile for multi-agent swarm members.
  Defines model configuration, reasoning depth, temperature, allowed tools, and prompt presets.
  """

  @derive Jason.Encoder
  @enforce_keys [:role, :display_name]
  defstruct [
    :role,
    :sub_role,
    :display_name,
    model_provider: "anthropic",
    model_id: "claude-3-7-sonnet",
    reasoning_effort: "medium",
    temperature: 0.3,
    allowed_tools: [:view_file, :grep_search],
    prompt_template: nil,
    state: :idle
  ]

  @type role :: :explorer | :architect | :coder | :auditor | :synthesizer | :verifier
  @type sub_role :: :security_auditor | :test_runner | nil

  @type t :: %__MODULE__{
          role: role(),
          sub_role: sub_role(),
          display_name: String.t(),
          model_provider: String.t(),
          model_id: String.t(),
          reasoning_effort: String.t() | atom(),
          temperature: float(),
          allowed_tools: [atom()],
          prompt_template: String.t() | nil,
          state: atom()
        }

  @doc """
  Creates a new RoleSpec struct with attribute normalization and temperature clamping.
  """
  @spec new(map() | keyword()) :: t()
  def new(attrs) when is_list(attrs), do: new(Map.new(attrs))

  def new(attrs) when is_map(attrs) do
    role = normalize_atom(get_attr(attrs, :role, :coder))
    sub_role = normalize_nullable_atom(get_attr(attrs, :sub_role, nil))
    display_name = to_string(get_attr(attrs, :display_name, default_display_name(role, sub_role)))
    model_provider = to_string(get_attr(attrs, :model_provider, "anthropic"))
    model_id = to_string(get_attr(attrs, :model_id, "claude-3-7-sonnet"))
    reasoning_effort = get_attr(attrs, :reasoning_effort, "medium")
    temperature = clamp_temp(get_attr(attrs, :temperature, 0.3))

    allowed_tools =
      attrs
      |> get_attr(:allowed_tools, default_tools_for_role(role, sub_role))
      |> List.wrap()
      |> Enum.map(&normalize_atom/1)

    prompt_template = get_attr(attrs, :prompt_template, nil)
    state = normalize_atom(get_attr(attrs, :state, :idle))

    %__MODULE__{
      role: role,
      sub_role: sub_role,
      display_name: display_name,
      model_provider: model_provider,
      model_id: model_id,
      reasoning_effort: reasoning_effort,
      temperature: temperature,
      allowed_tools: allowed_tools,
      prompt_template: prompt_template,
      state: state
    }
  end

  def default_tools_for_role(:explorer, _),
    do: [:view_file, :grep_search, :list_dir, :find_by_name]

  def default_tools_for_role(:architect, _), do: [:view_file, :grep_search]

  def default_tools_for_role(:coder, _),
    do: [:view_file, :grep_search, :replace_file_content, :write_to_file]

  def default_tools_for_role(:auditor, :security_auditor), do: [:view_file, :grep_search]
  def default_tools_for_role(:auditor, _), do: [:view_file, :grep_search]
  def default_tools_for_role(:verifier, _), do: [:view_file, :grep_search, :run_command]
  def default_tools_for_role(:synthesizer, _), do: [:view_file]
  def default_tools_for_role(_, _), do: [:view_file, :grep_search]

  defp default_display_name(role, nil), do: String.capitalize(to_string(role))

  defp default_display_name(role, sub_role) do
    "#{String.capitalize(to_string(role))} (#{Macro.camelize(to_string(sub_role))})"
  end

  defp get_attr(map, key, default) do
    Map.get(map, key) || Map.get(map, to_string(key)) || default
  end

  defp normalize_atom(val) when is_atom(val), do: val

  defp normalize_atom(val) when is_binary(val) do
    try do
      String.to_existing_atom(val)
    rescue
      ArgumentError -> :unknown
    end
  end

  defp normalize_atom(_), do: :unknown

  defp normalize_nullable_atom(nil), do: nil
  defp normalize_nullable_atom(val), do: normalize_atom(val)

  defp clamp_temp(val) when is_number(val) do
    cond do
      val < 0.0 -> 0.0
      val > 1.0 -> 1.0
      true -> val * 1.0
    end
  end

  defp clamp_temp(_), do: 0.3
end
