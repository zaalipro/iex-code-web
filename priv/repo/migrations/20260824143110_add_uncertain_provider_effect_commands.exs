defmodule IexCode.Repo.Migrations.AddUncertainProviderEffectCommands do
  use Ecto.Migration

  def up do
    execute(
      """
      CREATE TRIGGER run_commands_status_insert
      BEFORE INSERT ON run_commands
      FOR EACH ROW
      WHEN NEW.status NOT IN (
        'queued', 'claimed', 'running', 'waiting_approval', 'completed',
        'failed', 'cancelled', 'interrupted', 'uncertain'
      )
      BEGIN
        SELECT RAISE(ABORT, 'run_command_status_invalid');
      END
      """,
      "DROP TRIGGER IF EXISTS run_commands_status_insert"
    )

    execute(
      """
      CREATE TRIGGER run_commands_status_update
      BEFORE UPDATE OF status ON run_commands
      FOR EACH ROW
      WHEN NEW.status NOT IN (
        'queued', 'claimed', 'running', 'waiting_approval', 'completed',
        'failed', 'cancelled', 'interrupted', 'uncertain'
      )
      BEGIN
        SELECT RAISE(ABORT, 'run_command_status_invalid');
      END
      """,
      "DROP TRIGGER IF EXISTS run_commands_status_update"
    )

    execute(
      """
      CREATE TRIGGER run_commands_uncertain_terminal
      BEFORE UPDATE ON run_commands
      FOR EACH ROW
      WHEN OLD.status = 'uncertain'
      BEGIN
        SELECT RAISE(ABORT, 'run_command_uncertain_terminal');
      END
      """,
      "DROP TRIGGER IF EXISTS run_commands_uncertain_terminal"
    )
  end

  def down do
    execute("DROP TRIGGER IF EXISTS run_commands_uncertain_terminal")

    execute("""
    UPDATE run_commands
    SET status = 'failed',
        error_message = 'provider_usage_uncertain',
        error_details = '{"code":"provider_usage_uncertain"}'
    WHERE status = 'uncertain'
    """)

    execute("DROP TRIGGER IF EXISTS run_commands_status_update")
    execute("DROP TRIGGER IF EXISTS run_commands_status_insert")
  end
end
