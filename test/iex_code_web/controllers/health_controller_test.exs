defmodule IexCodeWeb.HealthControllerTest do
  use IexCodeWeb.ConnCase, async: false

  test "liveness is public and discloses no runtime details", %{conn: conn} do
    conn = conn |> Plug.Conn.delete_req_header("x-iex-code-test-auth") |> get("/health/live")

    assert json_response(conn, 200) == %{"status" => "ok"}
  end

  test "readiness confirms the single application instance is operational", %{conn: conn} do
    conn = conn |> Plug.Conn.delete_req_header("x-iex-code-test-auth") |> get("/health/ready")

    assert json_response(conn, 200) == %{"status" => "ready"}
  end
end
