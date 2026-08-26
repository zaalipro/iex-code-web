defmodule IexCode.Repo.Migrations.AddSettingsLockVersion do
  use Ecto.Migration

  def change do
    alter table(:app_settings) do
      add :lock_version, :integer, null: false, default: 1
    end
  end
end
