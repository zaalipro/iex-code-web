defmodule IexCodeWeb.LayoutsRootTest do
  use IexCodeWeb.ConnCase, async: true

  setup %{conn: conn} do
    {:ok, conn: conn |> recycle() |> unauthenticated_conn()}
  end

  test "renders explicit light theme metadata from the request cookie", %{conn: conn} do
    document =
      conn
      |> Plug.Test.put_req_cookie("iexcode_theme", "light")
      |> get(~p"/login")
      |> html_response(200)
      |> LazyHTML.from_document()

    assert document
           |> LazyHTML.query(~s(html[data-theme="light"][style="color-scheme: light;"]))
           |> Enum.any?()

    assert document
           |> LazyHTML.query(~s|meta[name="theme-color"][content="#EAE5DC"]:not([media])|)
           |> Enum.any?()

    assert document
           |> LazyHTML.query(~s(meta[name="theme-color"][media]))
           |> Enum.empty?()
  end

  test "renders explicit dark theme metadata from the request cookie", %{conn: conn} do
    document =
      conn
      |> Plug.Test.put_req_cookie("iexcode_theme", "dark")
      |> get(~p"/login")
      |> html_response(200)
      |> LazyHTML.from_document()

    assert document
           |> LazyHTML.query(~s(html[data-theme="dark"][style="color-scheme: dark;"]))
           |> Enum.any?()

    assert document
           |> LazyHTML.query(~s|meta[name="theme-color"][content="#171514"]:not([media])|)
           |> Enum.any?()

    assert document
           |> LazyHTML.query(~s(meta[name="theme-color"][media]))
           |> Enum.empty?()
  end

  test "uses system metadata and omits an explicit root theme when the cookie is absent", %{
    conn: conn
  } do
    document = conn |> get(~p"/login") |> html_response(200) |> LazyHTML.from_document()

    assert document |> LazyHTML.query("html[data-theme]") |> Enum.empty?()
    assert document
           |> LazyHTML.query(~s|html[style="color-scheme: light dark;"]|)
           |> Enum.any?()

    assert document
           |> LazyHTML.query(
             ~s|meta[name="theme-color"][content="#171514"][media="(prefers-color-scheme: dark)"]|
           )
           |> Enum.any?()

    assert document
           |> LazyHTML.query(
             ~s|meta[name="theme-color"][content="#EAE5DC"][media="(prefers-color-scheme: light)"]|
           )
           |> Enum.any?()
  end

  test "invalid cookie values use system metadata and keep connection status hidden", %{
    conn: conn
  } do
    document =
      conn
      |> Plug.Test.put_req_cookie("iexcode_theme", "blue")
      |> get(~p"/login")
      |> html_response(200)
      |> LazyHTML.from_document()

    assert document |> LazyHTML.query("html[data-theme]") |> Enum.empty?()
    assert document
           |> LazyHTML.query(~s|html[style="color-scheme: light dark;"]|)
           |> Enum.any?()

    assert document
           |> LazyHTML.query(
             ~s|meta[name="theme-color"][content="#171514"][media="(prefers-color-scheme: dark)"]|
           )
           |> Enum.any?()

    assert document
           |> LazyHTML.query(
             ~s|meta[name="theme-color"][content="#EAE5DC"][media="(prefers-color-scheme: light)"]|
           )
           |> Enum.any?()

    assert document
           |> LazyHTML.query(
             ~s|body > #connection-status[role="status"][aria-live="polite"][hidden]|
           )
           |> Enum.any?()
  end
end
