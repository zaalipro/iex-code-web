defmodule IexCode.Repo.Migrations.AddRunRequestFingerprint do
  use Ecto.Migration

  def up do
    alter table(:runs) do
      add :request_fingerprint, :string
    end

    # No keyed rows normally exist between the immediately preceding
    # request-key migration and this one. If an intermediate development build
    # did create one, assign an opaque value rather than guessing an original
    # request from mutable run state.
    execute("""
    UPDATE runs
    SET request_fingerprint = lower(hex(randomblob(32)))
    WHERE request_key IS NOT NULL AND request_fingerprint IS NULL
    """)

    execute(
      fingerprint_shape_trigger("runs_request_fingerprint_shape_insert", "INSERT"),
      "DROP TRIGGER IF EXISTS runs_request_fingerprint_shape_insert"
    )

    execute(
      fingerprint_shape_trigger("runs_request_fingerprint_shape_update", "UPDATE"),
      "DROP TRIGGER IF EXISTS runs_request_fingerprint_shape_update"
    )

    execute(
      """
      CREATE TRIGGER runs_request_fingerprint_immutable
      BEFORE UPDATE OF request_fingerprint ON runs
      FOR EACH ROW
      WHEN NEW.request_fingerprint IS NOT OLD.request_fingerprint
      BEGIN
        SELECT RAISE(ABORT, 'run_request_fingerprint_immutable');
      END
      """,
      "DROP TRIGGER IF EXISTS runs_request_fingerprint_immutable"
    )
  end

  def down do
    execute("DROP TRIGGER IF EXISTS runs_request_fingerprint_immutable")
    execute("DROP TRIGGER IF EXISTS runs_request_fingerprint_shape_update")
    execute("DROP TRIGGER IF EXISTS runs_request_fingerprint_shape_insert")

    alter table(:runs) do
      remove :request_fingerprint
    end
  end

  defp fingerprint_shape_trigger(name, operation) do
    """
    CREATE TRIGGER #{name}
    BEFORE #{operation} ON runs
    FOR EACH ROW
    WHEN (NEW.request_key IS NULL AND NEW.request_fingerprint IS NOT NULL)
      OR (NEW.request_key IS NOT NULL AND (
        NEW.request_fingerprint IS NULL
        OR length(NEW.request_fingerprint) != 64
        OR NEW.request_fingerprint GLOB '*[^0-9a-f]*'
      ))
    BEGIN
      SELECT RAISE(ABORT, 'run_request_fingerprint_invalid');
    END
    """
  end
end
