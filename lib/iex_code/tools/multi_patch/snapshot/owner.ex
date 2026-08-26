defmodule IexCode.Tools.MultiPatch.Snapshot.Owner do
  @moduledoc """
  GenServer that owns the ETS table backing `IexCode.Tools.MultiPatch.Snapshot`.

  Add it to the supervision tree (e.g. `{IexCode.Tools.MultiPatch.Snapshot.Owner, []}`)
  so the table has a well-defined lifecycle. If the table was already created
  lazily via `IexCode.Tools.MultiPatch.Snapshot.ensure_table/0` before this
  process started, the existing table is kept as-is.
  """

  use GenServer

  alias IexCode.Tools.MultiPatch.Snapshot

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))
  end

  @impl true
  def init(:ok) do
    case :ets.whereis(Snapshot.table_name()) do
      :undefined -> Snapshot.ensure_table()
      _table -> :ok
    end

    {:ok, %{}}
  end
end
