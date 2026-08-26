defmodule IexCode.DatabasePermissions do
  @moduledoc "Keeps local SQLite database and WAL sidecars private to the launching user."

  use GenServer

  @interval :timer.seconds(30)

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    secure_files()
    Process.send_after(self(), :secure, @interval)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:secure, state) do
    secure_files()
    Process.send_after(self(), :secure, @interval)
    {:noreply, state}
  end

  defp secure_files do
    case IexCode.Repo.config()[:database] do
      database when is_binary(database) and database not in ["", ":memory:"] ->
        Enum.each([database, database <> "-wal", database <> "-shm"], fn path ->
          if File.exists?(path), do: File.chmod(path, 0o600)
        end)

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end
end
