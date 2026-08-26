defmodule IexCodeWeb.AdminSessionController do
  use IexCodeWeb, :controller

  alias IexCodeWeb.AdminAuth

  def new(conn, _params) do
    if AdminAuth.authenticated?(conn) do
      redirect(conn, to: ~p"/")
    else
      render_login(conn)
    end
  end

  def create(conn, %{"admin" => %{"token" => token}}) when is_binary(token) do
    if AdminAuth.allow_attempt?(conn.remote_ip) and AdminAuth.valid_token?(token) do
      :ok = AdminAuth.clear_attempts(conn.remote_ip)

      conn
      |> AdminAuth.sign_in()
      |> redirect(to: ~p"/")
    else
      authentication_failed(conn)
    end
  end

  def create(conn, _params) do
    _allowed? = AdminAuth.allow_attempt?(conn.remote_ip)
    authentication_failed(conn)
  end

  def delete(conn, _params) do
    conn
    |> AdminAuth.sign_out()
    |> redirect(to: ~p"/login")
  end

  defp authentication_failed(conn) do
    conn
    |> put_status(:unauthorized)
    |> render_login("Unable to sign in. Check the token and try again.")
  end

  defp render_login(conn, error \\ nil) do
    render(conn, :new,
      page_title: "Secure sign in",
      form: Phoenix.Component.to_form(%{"token" => ""}, as: :admin),
      error: error,
      configured?: AdminAuth.configured?()
    )
  end
end
