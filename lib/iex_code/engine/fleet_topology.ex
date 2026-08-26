defmodule IexCode.Engine.FleetTopology do
  @moduledoc false

  @max_agents 32

  def manifest(requested_count) do
    count = requested_count |> normalize_count() |> max(4) |> min(@max_agents)

    roles = [:planner] ++ List.duplicate(:explorer, count - 3) ++ [:coder, :verifier]

    roles
    |> Enum.reduce({[], %{}}, fn role, {specs, ordinals} ->
      ordinal = Map.get(ordinals, role, 0)
      key = "#{role}:#{ordinal}"

      spec = %{
        key: key,
        role: Atom.to_string(role),
        adapter: Atom.to_string(role),
        display_name: display_name(role, ordinal),
        position: length(specs),
        required: role != :explorer or ordinal == 0,
        max_attempts: 3,
        capabilities: capabilities(role)
      }

      {specs ++ [spec], Map.put(ordinals, role, ordinal + 1)}
    end)
    |> elem(0)
  end

  defp normalize_count(value) when is_integer(value) and value > 0, do: value
  defp normalize_count(_value), do: 4

  defp display_name(:explorer, ordinal), do: "Explorer #{ordinal + 1}"
  defp display_name(role, _ordinal), do: role |> Atom.to_string() |> String.capitalize()

  defp capabilities(:planner), do: ["read", "plan"]
  defp capabilities(:explorer), do: ["read", "search"]
  defp capabilities(:coder), do: ["read", "write", "tool"]
  defp capabilities(:verifier), do: ["read", "test"]
end
