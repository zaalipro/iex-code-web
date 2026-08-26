defmodule IexCode.Runs.DagStepHandlers.ReadFile do
  @moduledoc false
  @behaviour IexCode.Runs.DagStepHandler

  alias IexCode.Runs.DagStepHandlers.Path

  @max_bytes 256_000
  @impl true
  def descriptor do
    %{
      kind: "read_file",
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
    if Map.keys(params) != ["path"] do
      {:error, {:params, :invalid_fields}}
    else
      case Map.get(params, "path") do
        path when is_binary(path) and byte_size(path) in 1..4_096 ->
          case Path.authorize_read(path) do
            :ok -> :ok
            {:error, :sensitive_path_forbidden} -> {:error, {:params, :sensitive_path_forbidden}}
          end

        _path ->
          {:error, {:params, :path_required}}
      end
    end
  end

  @impl true
  def execute(%{"path" => relative}, context) do
    with false <- context.cancelled?.(),
         :ok <- Path.authorize_read(relative),
         {:ok, path} <- Path.resolve(context.project_root, relative),
         {:ok, stat} <- File.stat(path),
         true <- stat.type == :regular or {:error, :not_a_regular_file},
         true <- stat.size <= @max_bytes or {:error, {:file_too_large, @max_bytes}},
         {:ok, content} <- File.read(path),
         true <- String.valid?(content) or {:error, :invalid_utf8} do
      {:ok, %{"path" => relative, "content" => content, "byte_size" => byte_size(content)}}
    else
      true -> {:error, :cancelled}
      {:error, reason} -> {:error, reason}
      false -> {:error, :invalid_file}
    end
  end
end
