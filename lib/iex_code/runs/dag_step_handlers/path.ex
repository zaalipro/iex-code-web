defmodule IexCode.Runs.DagStepHandlers.Path do
  @moduledoc false

  @sensitive_directories ~w(.aws .git .gnupg .ssh)
  @sensitive_names ~w(
    .env
    .netrc
    .npmrc
    .pypirc
    credentials
    credentials.json
    id_dsa
    id_ecdsa
    id_ed25519
    id_rsa
    secrets
    secrets.json
    service-account.json
  )
  @sensitive_extensions ~w(.jks .key .p12 .pem .pfx)

  defdelegate resolve(project_root, relative_path), to: IexCode.WorkspacePath

  def authorize_read(path) when is_binary(path) do
    if sensitive?(path), do: {:error, :sensitive_path_forbidden}, else: :ok
  end

  def authorize_read(_path), do: {:error, :invalid_path}

  def visible_entry?(parent, entry) when is_binary(parent) and is_binary(entry),
    do: not sensitive?(Path.join(parent, entry))

  defp sensitive?(path) do
    segments = path |> String.replace("\\", "/") |> String.split("/", trim: true)
    normalized = Enum.map(segments, &String.downcase/1)
    basename = List.last(normalized) || ""

    Enum.any?(normalized, &(&1 in @sensitive_directories)) or
      basename in @sensitive_names or String.starts_with?(basename, ".env.") or
      String.contains?(basename, "secret") or
      Enum.any?(@sensitive_extensions, &String.ends_with?(basename, &1))
  end
end
