defmodule IexCode.ControlReceiptOwnershipRepo do
  @moduledoc false

  use Ecto.Repo,
    otp_app: :iex_code,
    adapter: Ecto.Adapters.SQLite3

  @impl true
  def init(_type, config) do
    {:ok,
     config
     |> Keyword.put(:database, ":memory:")
     |> Keyword.put(:pool, Ecto.Adapters.SQL.Sandbox)
     |> Keyword.put(:pool_size, 1)
     |> Keyword.put(:ownership_timeout, 1_000)
     |> Keyword.put(:timeout, 1_000)}
  end
end
