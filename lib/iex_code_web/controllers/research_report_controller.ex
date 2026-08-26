defmodule IexCodeWeb.ResearchReportController do
  use IexCodeWeb, :controller

  alias IexCode.Research.Results

  @report_csp "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"

  def show(conn, %{"id" => id}) do
    with result when not is_nil(result) <- Results.get_ready(id),
         {:ok, html} <- Results.read_html(result) do
      conn
      |> report_headers("text/html", nil)
      |> send_resp(:ok, html)
    else
      _missing -> not_found(conn)
    end
  end

  def download_html(conn, %{"id" => id}) do
    with result when not is_nil(result) <- Results.get_ready(id),
         {:ok, html} <- Results.read_html(result) do
      conn
      |> report_headers("text/html", "deep-research-#{result.id}.html")
      |> send_resp(:ok, html)
    else
      _missing -> not_found(conn)
    end
  end

  def download_markdown(conn, %{"id" => id}) do
    with result when not is_nil(result) <- Results.get_ready(id),
         {:ok, markdown} <- Results.read_markdown(result) do
      conn
      |> report_headers("text/markdown", "deep-research-#{result.id}.md")
      |> send_resp(:ok, markdown)
    else
      _missing -> not_found(conn)
    end
  end

  defp report_headers(conn, media_type, filename) do
    conn =
      conn
      |> put_resp_content_type(media_type, "utf-8")
      |> put_resp_header("content-security-policy", @report_csp)
      |> put_resp_header("referrer-policy", "no-referrer")
      |> put_resp_header("cache-control", "private, no-store")
      |> put_resp_header("x-content-type-options", "nosniff")

    if filename do
      put_resp_header(conn, "content-disposition", ~s(attachment; filename="#{filename}"))
    else
      conn
    end
  end

  defp not_found(conn) do
    conn
    |> put_resp_content_type("text/plain", "utf-8")
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(:not_found, "Research result not found")
  end
end
