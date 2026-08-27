defmodule IexCode.Tools.MultiPatch.Snapshot.Owner do
  @moduledoc """
  GenServer that owns the empty legacy ETS compatibility table for
  `IexCode.Tools.MultiPatch.Snapshot`.

  Add it to the supervision tree (e.g. `{IexCode.Tools.MultiPatch.Snapshot.Owner, []}`)
  so the table has a well-defined lifecycle. SQLite owns the actual rollback
  manifests; startup purges any body-bearing entries left by an older version.
  """

  use GenServer

  alias IexCode.Tools.MultiPatch.Snapshot

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))
  end

  @impl true
  def init(:ok) do
    Snapshot.purge_legacy_cache()

    {:ok, %{}}
  end
end
