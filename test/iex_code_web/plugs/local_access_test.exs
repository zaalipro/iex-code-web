defmodule IexCodeWeb.Plugs.LocalAccessTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias IexCodeWeb.Plugs.LocalAccess

  setup do
    previous = System.get_env("IEX_CODE_ALLOW_REMOTE")
    System.delete_env("IEX_CODE_ALLOW_REMOTE")

    on_exit(fn ->
      if previous,
        do: System.put_env("IEX_CODE_ALLOW_REMOTE", previous),
        else: System.delete_env("IEX_CODE_ALLOW_REMOTE")
    end)
  end

  test "allows IPv4 and IPv6 loopback" do
    refute LocalAccess.call(local_conn({127, 0, 0, 1}, "localhost"), []).halted

    refute LocalAccess.call(local_conn({0, 0, 0, 0, 0, 0, 0, 1}, "::1"), []).halted
  end

  test "rejects remote clients by default" do
    conn = LocalAccess.call(%{conn(:get, "/") | remote_ip: {10, 10, 0, 4}}, [])
    assert conn.halted
    assert conn.status == 403
  end

  test "requires an explicit environment opt-in for remote access" do
    System.put_env("IEX_CODE_ALLOW_REMOTE", "true")
    refute LocalAccess.call(%{conn(:get, "/") | remote_ip: {10, 10, 0, 4}}, []).halted
  end

  test "rejects DNS rebinding hostnames even over a loopback connection" do
    conn = LocalAccess.call(local_conn({127, 0, 0, 1}, "attacker.example"), [])
    assert conn.halted
    assert conn.status == 403
  end

  test "allows loopback IP and localhost subdomain Host values" do
    refute LocalAccess.call(local_conn({127, 0, 0, 1}, "127.0.0.1"), []).halted
    refute LocalAccess.call(local_conn({127, 0, 0, 1}, "app.localhost"), []).halted
  end

  defp local_conn(remote_ip, host), do: %{conn(:get, "/") | remote_ip: remote_ip, host: host}
end
