defmodule IexCode.Research.HTMLReportTest do
  use ExUnit.Case, async: true

  alias IexCode.Research.HTMLReport

  test "renders a self-contained editorial report with safe citations and structured data" do
    markdown = """
    # Hardware feasibility brief

    A concise **finding** with `measured data` and [Source 1](https://example.com/report?q=1).

    ## Decision

    | Option | Result |
    | --- | --- |
    | A | Preferred |

    - Evidence retained
    - Limits disclosed
    """

    assert {:ok, html} =
             HTMLReport.render(markdown,
               subtitle: "Verification dossier",
               generated_at: ~U[2026-08-24 12:00:00Z],
               source_count: 1
             )

    assert html =~ "<!doctype html>"
    assert html =~ "Hardware feasibility brief"
    assert html =~ "Verification dossier"
    assert html =~ ~s(<div class="table-wrap"><table>)
    assert html =~ ~s(href="https://example.com/report?q=1")
    assert html =~ ~s(rel="noopener noreferrer nofollow")
    assert html =~ "@media print"
    refute html =~ "<script"
    refute html =~ "<link"
  end

  test "escapes active content and refuses unsafe link protocols" do
    markdown = """
    # <img src=x onerror=alert(1)> Report

    <script>alert(document.cookie)</script>

    [click](javascript:alert(1)) [local](file:///etc/passwd)
    """

    assert {:ok, html} = HTMLReport.render(markdown)
    assert html =~ "&lt;script&gt;alert(document.cookie)&lt;/script&gt;"
    assert html =~ "&lt;img src=x onerror=alert(1)&gt;"
    refute html =~ "<script"
    refute html =~ "javascript:"
    refute html =~ ~s(href="file:)

    assert {:ok, document} = Floki.parse_document(html)
    assert Floki.find(document, "script, link, iframe, object, embed, img, form") == []

    assert Enum.all?(Floki.find(document, "a"), fn anchor ->
             anchor
             |> Floki.attribute("href")
             |> Enum.all?(&String.starts_with?(&1, ["https://", "http://"]))
           end)
  end

  test "bounds input and validates UTF-8" do
    assert {:error, {:markdown_too_large, 2_000_000}} =
             HTMLReport.render(String.duplicate("x", 2_000_001))

    assert {:error, :invalid_utf8} = HTMLReport.render(<<255>>)
  end

  test "renders angle-bracket source-index destinations as safe links" do
    assert {:ok, html} =
             HTMLReport.render("[Primary source](<https://example.com/report?q=1>)")

    assert html =~ ~s(href="https://example.com/report?q=1")
  end
end
