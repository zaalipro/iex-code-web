defmodule IexCodeWeb.ResearchReportControllerTest do
  use IexCodeWeb.ConnCase, async: false

  alias IexCode.Research.Results
  alias IexCode.{Projects, Runs, Sessions}

  setup do
    workspace = temporary_directory("workspace")
    app_dir = temporary_directory("app")
    File.mkdir_p!(workspace)
    File.mkdir_p!(app_dir)

    prior_app_dir = Application.get_env(:iex_code, :app_dir)
    Application.put_env(:iex_code, :app_dir, app_dir)

    on_exit(fn ->
      if prior_app_dir do
        Application.put_env(:iex_code, :app_dir, prior_app_dir)
      else
        Application.delete_env(:iex_code, :app_dir)
      end

      File.rm_rf(workspace)
      File.rm_rf(app_dir)
    end)

    {:ok, project} = Projects.create_project(%{name: "Report route", root_path: workspace})
    {:ok, session} = Sessions.create_session(%{project_id: project.id, title: "Report"})

    {:ok, run} =
      Runs.create_run(%{
        project_id: project.id,
        session_id: session.id,
        objective: "Route-safe research report",
        kind: "deep_research",
        mode: "research",
        metadata: %{"research" => %{"level" => "high"}}
      })

    result = Results.get_by_run(run)
    {:ok, result} = Results.mark_running(result)

    {:ok, result} =
      Results.commit(result, "# Route-safe report\n\nGrounded evidence [1].", source_count: 1)

    %{result: result, app_dir: app_dir}
  end

  test "opens verified HTML in-browser with a locked-down response policy", %{
    conn: conn,
    result: result
  } do
    conn = get(conn, "/research/#{result.id}/report")

    assert response(conn, 200) =~ "<!doctype html>"
    assert get_resp_header(conn, "content-type") == ["text/html; charset=utf-8"]
    assert get_resp_header(conn, "cache-control") == ["private, no-store"]
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    assert get_resp_header(conn, "content-disposition") == []
    assert get_resp_header(conn, "content-security-policy") |> hd() =~ "default-src 'none'"
  end

  test "downloads HTML and Markdown with integer-ID filenames", %{conn: conn, result: result} do
    html_conn = get(conn, "/research/#{result.id}/report/download")
    assert response(html_conn, 200) =~ "Route-safe report"

    assert get_resp_header(html_conn, "content-disposition") == [
             ~s(attachment; filename="deep-research-#{result.id}.html")
           ]

    markdown_conn =
      conn
      |> recycle()
      |> authenticated_conn()
      |> get("/research/#{result.id}/result/download")

    assert response(markdown_conn, 200) == "# Route-safe report\n\nGrounded evidence [1]."

    assert get_resp_header(markdown_conn, "content-disposition") == [
             ~s(attachment; filename="deep-research-#{result.id}.md")
           ]
  end

  test "fails closed for missing, unfinished, and checksum-invalid reports", context do
    assert context.conn |> get("/research/999999/report") |> response(404) ==
             "Research result not found"

    oversized_id = String.duplicate("9", 1_000)

    assert context.conn
           |> recycle()
           |> authenticated_conn()
           |> get("/research/#{oversized_id}/report")
           |> response(404) == "Research result not found"

    root = Path.join(context.app_dir, "research")
    File.write!(Path.join(root, context.result.html_path), "tampered")

    assert context.conn
           |> recycle()
           |> authenticated_conn()
           |> get("/research/#{context.result.id}/report")
           |> response(404) == "Research result not found"
  end

  defp temporary_directory(label) do
    Path.join(
      System.tmp_dir!(),
      "iex-code-research-controller-#{label}-#{System.unique_integer([:positive])}"
    )
  end
end
