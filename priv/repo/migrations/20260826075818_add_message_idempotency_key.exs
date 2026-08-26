defmodule IexCode.Repo.Migrations.AddMessageIdempotencyKey do
  use Ecto.Migration

  def up do
    alter table(:messages) do
      add :idempotency_key, :string
    end

    # Preserve the earliest durable user turn for each existing run. Historical
    # duplicates deliberately remain unkeyed rather than being deleted.
    execute("""
    UPDATE messages
    SET idempotency_key = 'run-user:' ||
      json_extract(CASE WHEN json_valid(metadata) THEN metadata ELSE NULL END, '$.run_id')
    WHERE id IN (
      SELECT message_id
      FROM (
        SELECT messages.id AS message_id,
               row_number() OVER (
                 PARTITION BY json_extract(
                   CASE WHEN json_valid(messages.metadata) THEN messages.metadata ELSE NULL END,
                   '$.run_id'
                 )
                 ORDER BY messages.inserted_at ASC, messages.id ASC
               ) AS position
        FROM messages
        INNER JOIN runs
          ON runs.id = json_extract(
            CASE WHEN json_valid(messages.metadata) THEN messages.metadata ELSE NULL END,
            '$.run_id'
          )
         AND runs.session_id = messages.session_id
        WHERE messages.role = 'user'
          AND messages.agent_name IN (
            'User', 'User (Goal)', 'User (Research)', 'User (Durable Run)'
          )
          AND messages.content IN (runs.objective, 'Goal: ' || runs.objective)
          AND messages.metadata IS NOT NULL
          AND json_valid(messages.metadata)
          AND json_type(
            CASE WHEN json_valid(messages.metadata) THEN messages.metadata ELSE NULL END,
            '$.run_id'
          ) = 'text'
      ) ranked
      WHERE position = 1
    )
    """)

    execute("""
    UPDATE messages
    SET idempotency_key = 'run-final:' ||
      json_extract(CASE WHEN json_valid(metadata) THEN metadata ELSE NULL END, '$.run_id')
    WHERE id IN (
      SELECT message_id
      FROM (
        SELECT messages.id AS message_id,
               row_number() OVER (
                 PARTITION BY json_extract(
                   CASE WHEN json_valid(messages.metadata) THEN messages.metadata ELSE NULL END,
                   '$.run_id'
                 )
                 ORDER BY messages.inserted_at ASC, messages.id ASC
               ) AS position
        FROM messages
        INNER JOIN runs
          ON runs.id = json_extract(
            CASE WHEN json_valid(messages.metadata) THEN messages.metadata ELSE NULL END,
            '$.run_id'
          )
         AND runs.session_id = messages.session_id
        WHERE messages.role = 'assistant'
          AND messages.metadata IS NOT NULL
          AND json_valid(messages.metadata)
          AND json_type(
            CASE WHEN json_valid(messages.metadata) THEN messages.metadata ELSE NULL END,
            '$.run_id'
          ) = 'text'
          AND json_extract(
            CASE WHEN json_valid(messages.metadata) THEN messages.metadata ELSE NULL END,
            '$.kind'
          ) = 'coding_agent'
      ) ranked
      WHERE position = 1
    )
    """)

    create unique_index(:messages, [:idempotency_key], name: :messages_idempotency_key_index)

    execute(
      shape_trigger("messages_idempotency_key_shape_insert", "INSERT"),
      "DROP TRIGGER IF EXISTS messages_idempotency_key_shape_insert"
    )

    execute(
      shape_trigger("messages_idempotency_key_shape_update", "UPDATE OF idempotency_key"),
      "DROP TRIGGER IF EXISTS messages_idempotency_key_shape_update"
    )

    execute(
      """
      CREATE TRIGGER messages_idempotency_key_immutable
      BEFORE UPDATE OF idempotency_key ON messages
      FOR EACH ROW
      WHEN NEW.idempotency_key IS NOT OLD.idempotency_key
      BEGIN
        SELECT RAISE(ABORT, 'message_idempotency_key_immutable');
      END
      """,
      "DROP TRIGGER IF EXISTS messages_idempotency_key_immutable"
    )
  end

  def down do
    execute("DROP TRIGGER IF EXISTS messages_idempotency_key_immutable")
    execute("DROP TRIGGER IF EXISTS messages_idempotency_key_shape_update")
    execute("DROP TRIGGER IF EXISTS messages_idempotency_key_shape_insert")

    drop_if_exists unique_index(:messages, [:idempotency_key],
                     name: :messages_idempotency_key_index
                   )

    alter table(:messages) do
      remove :idempotency_key
    end

    create_if_not_exists index(:messages, [:session_id], name: :messages_session_id_index)
  end

  defp shape_trigger(name, operation) do
    """
    CREATE TRIGGER #{name}
    BEFORE #{operation} ON messages
    FOR EACH ROW
    WHEN NEW.idempotency_key IS NOT NULL AND (
      length(NEW.idempotency_key) NOT BETWEEN 1 AND 200
      OR instr(NEW.idempotency_key, ' ') > 0
      OR instr(NEW.idempotency_key, char(9)) > 0
      OR instr(NEW.idempotency_key, char(10)) > 0
      OR instr(NEW.idempotency_key, char(13)) > 0
    )
    BEGIN
      SELECT RAISE(ABORT, 'message_idempotency_key_invalid');
    END
    """
  end
end
