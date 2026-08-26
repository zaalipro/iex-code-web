defmodule IexCode.SettingsEnvDefaultsTest do
  use IexCode.DataCase, async: false

  alias IexCode.Repo
  alias IexCode.Settings
  alias IexCode.Settings.AppSettings

  test "initial settings honor the deployment model provider and model environment" do
    previous_provider = System.get_env("IEX_CODE_DEFAULT_MODEL_PROVIDER")
    previous_model = System.get_env("IEX_CODE_DEFAULT_MODEL")
    previous_base_url = System.get_env("OPENAI_BASE_URL")

    System.put_env("IEX_CODE_DEFAULT_MODEL_PROVIDER", "openai")
    System.put_env("IEX_CODE_DEFAULT_MODEL", "ox-alpha")
    System.put_env("OPENAI_BASE_URL", "https://cli.llmotions.com/v1")
    Repo.delete_all(AppSettings)

    on_exit(fn ->
      restore_system_env("IEX_CODE_DEFAULT_MODEL_PROVIDER", previous_provider)
      restore_system_env("IEX_CODE_DEFAULT_MODEL", previous_model)
      restore_system_env("OPENAI_BASE_URL", previous_base_url)
    end)

    settings = Settings.get_settings()
    assert settings.default_model_provider == "openai"
    assert settings.default_model == "ox-alpha"
    assert settings.openai_base_url == "https://cli.llmotions.com/v1"
  end

  defp restore_system_env(name, nil), do: System.delete_env(name)
  defp restore_system_env(name, value), do: System.put_env(name, value)
end
