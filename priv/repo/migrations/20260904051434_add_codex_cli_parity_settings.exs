defmodule IexCode.Repo.Migrations.AddCodexCliParitySettings do
  use Ecto.Migration

  def change do
    alter table(:app_settings) do
      add :tool_approval_mode, :string, null: false, default: "prompt_dangerous"

      add :tool_category_overrides, :map,
        null: false,
        default: %{
          "shell_execution" => "prompt",
          "file_mutations" => "prompt",
          "git_push" => "prompt",
          "web_search" => "auto"
        }

      add :context_window_tokens, :integer, null: false, default: 128_000
      add :context_prune_threshold_percent, :integer, null: false, default: 75
      add :context_compaction_strategy, :string, null: false, default: "token_compaction"
      add :keep_recent_turns, :integer, null: false, default: 6
      add :custom_system_prompt, :text
      add :workspace_persona, :string, null: false, default: "pragmatic_engineer"
      add :coding_style_rules, :text
      add :custom_env_vars, :map, null: false, default: %{}
      add :sandbox_mode, :string, null: false, default: "inherit_filtered"
      add :sound_enabled, :boolean, null: false, default: true
      add :sound_volume, :integer, null: false, default: 80
      add :completion_chime, :string, null: false, default: "hero"
      add :error_alert_chime, :string, null: false, default: "basso"
      add :approval_prompt_chime, :string, null: false, default: "ping"
      add :theme_accent, :string, null: false, default: "cyan"
      add :layout_density, :string, null: false, default: "comfortable"
    end
  end
end
