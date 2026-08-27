defmodule IexCode.Repo.Migrations.AddResourcePolicySettings do
  use Ecto.Migration

  def change do
    alter table(:app_settings) do
      add :resource_pressure_percent, :integer, null: false, default: 70
      add :resource_critical_percent, :integer, null: false, default: 85
      add :terminal_idle_timeout_minutes, :integer, null: false, default: 30
      add :session_idle_timeout_minutes, :integer, null: false, default: 30
      add :output_artifact_limit_mib, :integer, null: false, default: 256
      add :output_spool_quota_mib, :integer, null: false, default: 2048
      add :output_retention_days, :integer, null: false, default: 7
    end

    # SQLite cannot add table constraints after a table has been created. Keep
    # these cross-field rules in AppSettings.changeset/2, which is the only
    # supported write path for the singleton settings row. The individual
    # columns remain non-null and have safe database defaults for upgrades.
  end
end
