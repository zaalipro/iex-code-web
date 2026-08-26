defmodule IexCode.Runs.DagStepHandlers.ProjectInventory do
  @moduledoc false
  @behaviour IexCode.Runs.DagStepHandler

  alias IexCode.Runs.DagStepHandlers.Path

  @max_entries 2_000

  @impl true
  def descriptor do
    %{
      kind: "project_inventory",
      version: 1,
      effect_class: :read,
      replay_policy: :safe,
      resource_contract: "project_read_v1",
      checkpoint_version: 1,
      max_output_bytes: 256_000,
      default_timeout_ms: 30_000
    }
  end

  @impl true
  def validate_params(params, _dependencies) do
    if Map.keys(params) -- ["path"] != [] do
      {:error, {:params, :unknown_fields}}
    else
      case Map.get(params, "path") do
        nil ->
          :ok

        path when is_binary(path) and byte_size(path) in 1..4_096 ->
          case Path.authorize_read(path) do
            :ok -> :ok
            {:error, :sensitive_path_forbidden} -> {:error, {:params, :sensitive_path_forbidden}}
          end

        _path ->
          {:error, {:params, :invalid_path}}
      end
    end
  end

  @impl true
  def execute(params, context) do
    relative = Map.get(params, "path", ".")

    with false <- context.cancelled?.(),
         :ok <- Path.authorize_read(relative),
         {:ok, root} <- Path.resolve(context.project_root, relative),
         {:ok, entries} <- File.ls(root) do
      entries =
        entries
        |> Enum.filter(&Path.visible_entry?(relative, &1))
        |> Enum.sort()
        |> Enum.take(@max_entries)

      {:ok,
       %{"path" => relative, "entries" => entries, "truncated" => length(entries) == @max_entries}}
    else
      true -> {:error, :cancelled}
      {:error, reason} -> {:error, reason}
    end
  end
end
