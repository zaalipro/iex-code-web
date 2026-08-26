defmodule IexCode.Settings.BootstrapTest do
  use IexCode.DataCase, async: false

  alias IexCode.Settings
  alias IexCode.Settings.Bootstrap

  test "imports only allowed one-time settings and unlinks the credential document" do
    path =
      Path.join(
        System.tmp_dir!(),
        "iex-code-bootstrap-#{System.unique_integer([:positive])}.json"
      )

    File.write!(
      path,
      Jason.encode!(%{
        "openai_api_key" => "bootstrap-canary",
        "openai_base_url" => "https://models.example.test/v1",
        "default_model_provider" => "openai",
        "default_model" => "bootstrap-model",
        "tavily_api_key" => "bootstrap-search-canary",
        "search_providers" => %{"attacker" => %{"enabled" => true}}
      })
    )

    on_exit(fn -> File.rm(path) end)
    previous = System.get_env("IEX_CODE_BOOTSTRAP_SETTINGS_FILE")
    System.put_env("IEX_CODE_BOOTSTRAP_SETTINGS_FILE", path)

    on_exit(fn ->
      if previous,
        do: System.put_env("IEX_CODE_BOOTSTRAP_SETTINGS_FILE", previous),
        else: System.delete_env("IEX_CODE_BOOTSTRAP_SETTINGS_FILE")
    end)

    assert :undefined = start_supervised!(Bootstrap)
    refute File.exists?(path)

    settings = Settings.get_settings()
    assert settings.openai_api_key == "bootstrap-canary"
    assert settings.openai_base_url == "https://models.example.test/v1"
    assert settings.default_model == "bootstrap-model"
    assert settings.search_providers["tavily"]["api_key"] == "bootstrap-search-canary"
    assert settings.search_providers["tavily"]["enabled"]
    refute Map.has_key?(settings.search_providers, "attacker")
  end

  test "rejects malformed bootstrap without deleting it" do
    path =
      Path.join(
        System.tmp_dir!(),
        "iex-code-bootstrap-bad-#{System.unique_integer([:positive])}.json"
      )

    File.write!(path, "not-json")
    on_exit(fn -> File.rm(path) end)

    previous = System.get_env("IEX_CODE_BOOTSTRAP_SETTINGS_FILE")
    System.put_env("IEX_CODE_BOOTSTRAP_SETTINGS_FILE", path)

    on_exit(fn ->
      if previous,
        do: System.put_env("IEX_CODE_BOOTSTRAP_SETTINGS_FILE", previous),
        else: System.delete_env("IEX_CODE_BOOTSTRAP_SETTINGS_FILE")
    end)

    assert :undefined = start_supervised!(Bootstrap)
    assert File.exists?(path)
  end
end
