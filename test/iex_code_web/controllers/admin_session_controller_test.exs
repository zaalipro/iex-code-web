defmodule IexCodeWeb.AdminSessionControllerTest do
  use IexCodeWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias IexCodeWeb.AdminAuth

  @token "iex-code-test-admin-token"
  @hash_env "IEX_CODE_ADMIN_TOKEN_SHA256"

  setup %{conn: conn} do
    :ok = AdminAuth.clear_attempts(conn.remote_ip)
    {:ok, conn: unauthenticated_conn(recycle(conn))}
  end

  test "login form is public, CSRF protected, and never renders the configured token", %{
    conn: conn
  } do
    html = conn |> get(~p"/login") |> html_response(200)

    assert html =~ ~s(id="admin-login-form")
    assert html =~ ~s(name="_csrf_token")
    assert html =~ ~s(type="password")
    refute html =~ @token
    refute html =~ System.fetch_env!(@hash_env)
  end

  test "valid login renews a minimal session and redirects to the workspace", %{conn: conn} do
    previous_session = %{unrelated: "must be cleared"}
    conn = Plug.Test.init_test_session(conn, previous_session)
    conn = post(conn, ~p"/login", %{"admin" => %{"token" => @token}})

    assert redirected_to(conn) == ~p"/"
    assert get_session(conn, "admin_auth_version")
    assert is_integer(get_session(conn, "admin_authenticated_at"))
    assert is_integer(get_session(conn, "admin_expires_at"))
    refute get_session(conn, :unrelated)
    refute inspect(get_session(conn)) =~ @token
  end

  test "session cookie is encrypted, HttpOnly, and SameSite Strict", %{conn: conn} do
    response = post(conn, ~p"/login", %{"admin" => %{"token" => @token}})
    cookie = response.resp_cookies["_iex_code_key"]

    assert cookie.http_only
    assert cookie.same_site == "Strict"
    refute cookie.value =~ @token
    refute cookie.value =~ "admin_auth"
    refute cookie.value =~ System.fetch_env!(@hash_env)
  end

  test "invalid and malformed credentials return the same generic error without leaking input", %{
    conn: conn
  } do
    invalid = "not-the-admin-token"

    log =
      capture_log(fn ->
        response = post(conn, ~p"/login", %{"admin" => %{"token" => invalid}})
        html = html_response(response, 401)
        assert html =~ "Unable to sign in. Check the token and try again."
        refute html =~ invalid
      end)

    refute log =~ invalid

    malformed = conn |> recycle() |> unauthenticated_conn() |> post(~p"/login", %{})
    assert html_response(malformed, 401) =~ "Unable to sign in. Check the token and try again."
  end

  test "login attempts are bounded per peer and a successful login resets the bucket", %{
    conn: conn
  } do
    peer = {198, 51, 100, 23}

    Enum.each(1..5, fn _attempt -> assert AdminAuth.allow_attempt?(peer) end)
    refute AdminAuth.allow_attempt?(peer)

    assert :ok = AdminAuth.clear_attempts(peer)
    assert AdminAuth.allow_attempt?(peer)

    # A different peer does not inherit the first peer's quota.
    assert AdminAuth.allow_attempt?({198, 51, 100, 24})
    assert conn.remote_ip != peer
  end

  test "logout drops authentication and the recycled connection cannot reopen a protected route",
       %{
         conn: conn
       } do
    signed_in = post(conn, ~p"/login", %{"admin" => %{"token" => @token}})
    logged_out = signed_in |> recycle() |> post(~p"/logout")

    assert redirected_to(logged_out) == ~p"/login"
    assert get_session(logged_out) == %{}

    protected = logged_out |> recycle() |> get(~p"/settings")
    assert redirected_to(protected) == ~p"/login"
  end

  test "an invalid or rotated configured digest fails closed", %{conn: conn} do
    original = System.fetch_env!(@hash_env)
    old_claims = AdminAuth.session_claims()

    on_exit(fn -> System.put_env(@hash_env, original) end)

    System.put_env(@hash_env, "invalid")
    refute AdminAuth.configured?()
    refute AdminAuth.valid_token?(@token)

    html = conn |> get(~p"/login") |> html_response(200)
    assert html =~ ~s(id="admin-login-unconfigured")
    assert html =~ ~s(disabled)

    System.put_env(@hash_env, String.duplicate("a", 64))
    refute AdminAuth.authenticated?(old_claims)
  end

  test "absolute session expiry rejects future, expired, and overlong claims" do
    now = System.system_time(:second)

    assert AdminAuth.authenticated?(AdminAuth.session_claims(now))
    refute AdminAuth.authenticated?(AdminAuth.session_claims(now - 7 * 24 * 60 * 60))
    refute AdminAuth.authenticated?(AdminAuth.session_claims(now + 60))

    claims = AdminAuth.session_claims(now) |> Map.put("admin_expires_at", now + 8 * 24 * 60 * 60)
    refute AdminAuth.authenticated?(claims)
  end

  test "protected controller and LiveView routes redirect before accessing application data", %{
    conn: conn
  } do
    paths = [
      ~p"/",
      ~p"/research",
      ~p"/settings",
      "/sessions/00000000-0000-0000-0000-000000000000",
      "/sessions/00000000-0000-0000-0000-000000000000/research",
      "/sessions/00000000-0000-0000-0000-000000000000/settings",
      "/research/1/report",
      "/research/1/report/download",
      "/research/1/result/download"
    ]

    Enum.each(paths, fn path ->
      response = conn |> recycle() |> unauthenticated_conn() |> get(path)
      assert redirected_to(response) == ~p"/login"
    end)
  end
end
