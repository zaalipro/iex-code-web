defmodule IexCodeWeb.Plugs.RequireAdmin do
  @moduledoc "Rejects requests that do not carry a current administrator session."

  import Phoenix.Controller, only: [put_flash: 3, redirect: 2]
  import Plug.Conn

  alias IexCodeWeb.AdminAuth

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    if AdminAuth.authenticated?(conn) do
      assign(conn, :current_scope, %{admin: true})
    else
      conn
      |> put_flash(:error, "Sign in to continue.")
      |> redirect(to: "/login")
      |> halt()
    end
  end
end
