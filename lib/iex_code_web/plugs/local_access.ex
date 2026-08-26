defmodule IexCodeWeb.Plugs.LocalAccess do
  @moduledoc """
  Refuses remote access to the native host-control workspace by default.

  IexCode can execute shell commands and write files directly on the host. A
  public bind therefore requires an explicit `IEX_CODE_ALLOW_REMOTE=true`
  opt-in and an authenticated reverse proxy. Loopback remains the safe default.
  """

  import Plug.Conn

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    if access_allowed?(conn) do
      conn
    else
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(403, "IexCode host controls are available only from this machine.")
      |> halt()
    end
  end

  defp access_allowed?(conn) do
    allow_remote?() or (local_address?(conn.remote_ip) and local_host?(conn.host))
  end

  defp allow_remote? do
    System.get_env("IEX_CODE_ALLOW_REMOTE") in ["1", "true", "TRUE"]
  end

  defp local_address?({127, _, _, _}), do: true
  defp local_address?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp local_address?({0, 0, 0, 0, 0, 65_535, 0x7F00, _}), do: true
  defp local_address?(_ip), do: false

  # Checking only the peer address permits DNS-rebinding attacks: an attacker
  # controlled hostname can resolve to 127.0.0.1 and make the browser treat the
  # local host-control app as the attacker's origin. Require a loopback Host as
  # well unless remote mode was explicitly enabled.
  defp local_host?(host) when is_binary(host) do
    normalized = host |> String.trim() |> String.downcase() |> String.trim_trailing(".")

    normalized == "localhost" or String.ends_with?(normalized, ".localhost") or
      parsed_local_address?(normalized)
  end

  defp local_host?(_host), do: false

  defp parsed_local_address?(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, ip} -> local_address?(ip)
      {:error, _} -> false
    end
  end
end
