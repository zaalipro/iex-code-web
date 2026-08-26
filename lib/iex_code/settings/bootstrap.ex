defmodule IexCode.Settings.Bootstrap do
  @moduledoc """
  Imports one root-provisioned settings document, then removes it.

  This keeps provider credentials out of the long-lived application environment,
  which is inherited by interactive terminal children. The resulting settings
  remain protected by the same local SQLite permissions as settings entered in
  the browser. It is a provisioning convenience, not a credential vault.
  """

  use GenServer

  require Logger

  alias IexCode.Settings

  @allowed_fields ~w(
    openai_api_key
    openai_base_url
    anthropic_api_key
    anthropic_base_url
    default_model_provider
    default_model
    temperature
    max_tokens
  )
  @tavily_base_url "https://api.tavily.com"
  @maximum_bytes 32_768

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    import_once()
    :ignore
  end

  defp import_once do
    case System.get_env("IEX_CODE_BOOTSTRAP_SETTINGS_FILE") do
      path when is_binary(path) and path != "" -> import_file(path)
      _missing -> :ok
    end
  end

  defp import_file(path) do
    with {:ok, stat} <- File.stat(path),
         true <- stat.type == :regular and stat.size <= @maximum_bytes,
         {:ok, body} <- File.read(path),
         {:ok, decoded} when is_map(decoded) <- Jason.decode(body),
         {:ok, attrs} <- bootstrap_attrs(decoded),
         true <- map_size(attrs) > 0,
         {:ok, _settings} <- Settings.update_settings(attrs) do
      Logger.info("Imported one-time model settings bootstrap")
      remove_bootstrap(path)
    else
      {:error, :enoent} ->
        :ok

      _invalid ->
        Logger.error("One-time model settings bootstrap was rejected")
        :ok
    end
  rescue
    _error ->
      Logger.error("One-time model settings bootstrap could not be imported")
      :ok
  end

  defp bootstrap_attrs(decoded) do
    attrs = Map.take(decoded, @allowed_fields)

    case Map.fetch(decoded, "tavily_api_key") do
      :error ->
        {:ok, attrs}

      {:ok, api_key}
      when is_binary(api_key) and api_key != "" and byte_size(api_key) <= 4_096 ->
        settings = Settings.get_settings()
        providers = settings.search_providers || %{}

        tavily =
          providers
          |> Map.get("tavily", %{})
          |> Map.put("enabled", true)
          |> Map.put("api_key", api_key)
          |> Map.put("base_url", @tavily_base_url)

        {:ok, Map.put(attrs, "search_providers", Map.put(providers, "tavily", tavily))}

      {:ok, _invalid} ->
        {:error, :invalid_tavily_api_key}
    end
  end

  defp remove_bootstrap(path) do
    # Best effort only: unlinking is the meaningful boundary on modern storage;
    # overwriting is intentionally avoided because copy-on-write filesystems do
    # not guarantee physical erasure.
    case File.rm(path) do
      :ok -> :ok
      {:error, _reason} -> Logger.warning("Imported settings bootstrap could not be removed")
    end
  end
end
