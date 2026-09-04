defmodule IexCode.Repo do
  use Ecto.Repo,
    otp_app: :iex_code,
    adapter: Ecto.Adapters.SQLite3

  @impl true
  def init(_type, config) do
    database = config[:database]

    if is_binary(database) and database not in ["", ":memory:"] do
      database |> Path.dirname() |> File.mkdir_p!()

      if File.exists?(database), do: File.chmod(database, 0o600)
    end

    {:ok, config}
  end

  @doc """
  Executes a function with exponential backoff retry on SQLite busy/locked errors.
  """
  def retry_on_busy(fun, attempts \\ 30, delay_ms \\ 50) do
    fun.()
  rescue
    e in [Exqlite.Error, DBConnection.ConnectionError] ->
      msg = Exception.message(e)

      if attempts > 1 and
           (is_struct(e, DBConnection.ConnectionError) or
              String.contains?(String.downcase(msg), "busy") or
              String.contains?(String.downcase(msg), "locked")) do
        Process.sleep(delay_ms)
        retry_on_busy(fun, attempts - 1, min(delay_ms * 2, 250))
      else
        reraise e, __STACKTRACE__
      end
  end

  @doc """
  Flushes SQLite write-ahead log (WAL) frames to the database file and truncates the WAL.
  Executes `PRAGMA wal_checkpoint(TRUNCATE);` with automatic fallback to `PRAGMA wal_checkpoint(PASSIVE);`
  if concurrent readers or table locks prevent immediate truncation.
  """
  @spec checkpoint_wal() :: {:ok, term()} | {:error, term()}
  def checkpoint_wal do
    case truncate_wal() do
      {:ok, res} ->
        {:ok, res}

      {:error, _reason} ->
        # Fall back to PASSIVE checkpoint so frames are flushed even if truncation is locked
        passive_wal()
    end
  end

  defp truncate_wal do
    retry_on_busy(
      fn ->
        result = Ecto.Adapters.SQL.query!(__MODULE__, "PRAGMA wal_checkpoint(TRUNCATE);", [])
        {:ok, result}
      end,
      3,
      10
    )
  rescue
    e -> {:error, e}
  catch
    :exit, e -> {:error, e}
  end

  defp passive_wal do
    retry_on_busy(
      fn ->
        result = Ecto.Adapters.SQL.query!(__MODULE__, "PRAGMA wal_checkpoint(PASSIVE);", [])
        {:ok, result}
      end,
      3,
      10
    )
  rescue
    e -> {:error, e}
  catch
    :exit, e -> {:error, e}
  end
end
