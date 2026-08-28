defmodule IexCodeWeb.Plugs.Theme do
  @moduledoc "Reads the browser's explicit light or dark theme preference."

  import Plug.Conn

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    conn = fetch_cookies(conn)

    theme_preference =
      case conn.req_cookies["iexcode_theme"] do
        preference when preference in ["dark", "light"] -> preference
        _absent_or_invalid -> nil
      end

    assign(conn, :theme_preference, theme_preference)
  end
end
