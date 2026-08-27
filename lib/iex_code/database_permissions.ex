defmodule IexCode.DatabasePermissions do
  @moduledoc "Keeps durable SQLite and output-spool storage private and periodically maintained."

  use GenServer

  @interval :timer.seconds(30)
  @default_output_cleanup_interval :timer.minutes(15)
  @output_cleanup_batch_size 500
  @max_output_cleanup_batches 8

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(_opts) do
    secure_files()
    Process.send_after(self(), :secure, @interval)
    cleanup_outputs()
    schedule_output_cleanup()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:secure, state) do
    secure_files()
    Process.send_after(self(), :secure, @interval)
    {:noreply, state}
  end

  def handle_info(:cleanup_outputs, state) do
    cleanup_outputs()
    schedule_output_cleanup()
    {:noreply, state}
  end

  defp cleanup_outputs do
    if :iex_code
       |> Application.get_env(:output_artifacts, [])
       |> Keyword.get(:enabled, true) do
      drain_output_cleanup(@max_output_cleanup_batches)
    end

    :ok
  end

  defp drain_output_cleanup(0), do: :ok

  defp drain_output_cleanup(remaining) do
    case IexCode.Outputs.cleanup_expired() do
      {:ok, @output_cleanup_batch_size} -> drain_output_cleanup(remaining - 1)
      _complete_or_failed -> :ok
    end
  end

  defp schedule_output_cleanup do
    configured =
      :iex_code
      |> Application.get_env(:output_artifacts, [])
      |> Keyword.get(:cleanup_interval_ms, @default_output_cleanup_interval)

    interval =
      if is_integer(configured) and configured > 0,
        do: configured,
        else: @default_output_cleanup_interval

    Process.send_after(self(), :cleanup_outputs, interval)
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
