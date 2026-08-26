defmodule IexCode.Repo.Migrations.HardenDurableRunAgentFleetCredentials do
  use Ecto.Migration

  # Early development builds stored the fleet-manager bearer directly. The
  # authoritative create migration now requires a lowercase SHA-256 digest;
  # this upgrade scrubs databases that applied the earlier shape in place.
  def up do
    execute(&hash_existing_credentials/0)
  end

  # A credential hash cannot and must not be reversed on rollback.
  def down, do: :ok

  defp hash_existing_credentials do
    hash_column("run_agents", "lease_owner")
    hash_column("run_agent_controls", "claim_owner")
  end

  defp hash_column(table, column) do
    %{rows: rows} =
      repo().query!("SELECT id, #{column} FROM #{table} WHERE #{column} IS NOT NULL", [],
        log: false
      )

    Enum.each(rows, fn [id, credential] ->
      unless digest?(credential) do
        digest = :crypto.hash(:sha256, credential) |> Base.encode16(case: :lower)

        repo().query!(
          "UPDATE #{table} SET #{column} = ? WHERE id = ? AND #{column} = ?",
          [
            digest,
            id,
            credential
          ],
          log: false
        )
      end
    end)
  end

  defp digest?(value) when is_binary(value),
    do: String.match?(value, ~r/^[0-9a-f]{64}$/)

  defp digest?(_value), do: false
end
