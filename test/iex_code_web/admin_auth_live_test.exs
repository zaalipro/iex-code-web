defmodule IexCodeWeb.AdminAuthLiveTest do
  use IexCodeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias IexCodeWeb.AdminAuth

  test "shared on_mount rejects a disconnected or connected mount without valid claims", %{
    conn: conn
  } do
    conn = conn |> recycle() |> unauthenticated_conn()

    assert {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/")

    socket = %Phoenix.LiveView.Socket{endpoint: IexCodeWeb.Endpoint}
    assert {:halt, redirected} = AdminAuth.on_mount(:require_admin, %{}, %{}, socket)
    assert redirected.redirected == {:redirect, %{status: 302, to: "/login"}}
  end

  test "shared on_mount assigns a minimal current scope for valid claims" do
    socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}}

    assert {:cont, authorized} =
             AdminAuth.on_mount(:require_admin, %{}, AdminAuth.session_claims(), socket)

    assert authorized.assigns.current_scope == %{admin: true}
  end
end
