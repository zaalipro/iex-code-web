defmodule IexCode.Repo.Migrations.AddExecutionPolicySettings do
  use Ecto.Migration

  def change do
    alter table(:app_settings) do
      add :default_dispatch_mode, :string, null: false, default: "background"
      add :default_run_mode, :string, null: false, default: "swarm"
      add :default_run_priority, :string, null: false, default: "normal"
      add :default_run_max_attempts, :integer, null: false, default: 3
      add :default_run_token_budget, :integer
      add :default_run_cost_budget_cents, :integer
      add :default_run_time_budget_minutes, :integer
      add :goal_auto_start, :boolean, null: false, default: true
      add :agent_max_turns, :integer, null: false, default: 8
      add :swarm_max_retries, :integer, null: false, default: 3

      add :default_tools, :map,
        null: false,
        default: %{"ast_search" => true, "web_search" => false}
    end

    execute(
      """
      UPDATE app_settings
      SET anthropic_base_url = COALESCE(NULLIF(anthropic_base_url, ''), 'https://api.anthropic.com'),
          openai_base_url = COALESCE(NULLIF(openai_base_url, ''), 'https://cli.llmotions.com/v1'),
          default_model_provider = COALESCE(NULLIF(default_model_provider, ''), 'openai'),
          default_model = COALESCE(NULLIF(default_model, ''), 'deepseek-v4-pro'),
          swarm_agent_count = CASE WHEN swarm_agent_count IS NULL OR swarm_agent_count < 4 THEN 4 ELSE swarm_agent_count END,
          auto_save = COALESCE(auto_save, 1),
          temperature = COALESCE(temperature, 0.2),
          max_tokens = COALESCE(max_tokens, 4096)
      """,
      "SELECT 1"
    )

    execute(
      "UPDATE app_settings SET research_max_sources = 40 WHERE research_max_sources > 40",
      "SELECT 1"
    )
  end
end
