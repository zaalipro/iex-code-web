defmodule IexCodeWeb.Plugs.ThemeTest do
  use ExUnit.Case, async: true

  alias IexCodeWeb.Plugs.Theme

  test "accepts only dark and light cookie values" do
    assert Theme.init(source: :cookie) == [source: :cookie]

    light =
      Plug.Test.conn(:get, "/")
      |> Plug.Test.put_req_cookie("iexcode_theme", "light")
      |> Theme.call([])

    dark =
      Plug.Test.conn(:get, "/")
      |> Plug.Test.put_req_cookie("iexcode_theme", "dark")
      |> Theme.call([])

    invalid =
      Plug.Test.conn(:get, "/")
      |> Plug.Test.put_req_cookie("iexcode_theme", "blue")
      |> Theme.call([])

    assert %{assigns: %{theme_preference: "light"}} = light
    assert %{assigns: %{theme_preference: "dark"}} = dark
    assert %{assigns: %{theme_preference: nil}} = invalid
  end

  test "assigns nil when the theme cookie is absent" do
    conn = Plug.Test.conn(:get, "/") |> Theme.call([])

    assert %{assigns: %{theme_preference: nil}} = conn
  end
end
