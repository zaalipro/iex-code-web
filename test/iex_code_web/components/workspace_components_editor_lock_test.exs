defmodule IexCodeWeb.WorkspaceComponentsEditorLockTest do
  use IexCode.E2E.Case, async: true

  import Phoenix.LiveViewTest

  alias IexCodeWeb.WorkspaceComponents

  test "file explorer renders foreign lock ownership as a disabled read-only editor" do
    lock = %{
      owner_id: "run:coder-42",
      resource_type: "file",
      resource_key: "/workspace/lib/demo.ex"
    }

    html =
      render_component(&WorkspaceComponents.file_explorer/1,
        files: ["lib/demo.ex"],
        selected_file: "lib/demo.ex",
        file_content: "defmodule Demo do\nend\n",
        dirty_content: "defmodule Demo do\n  # local edit\nend\n",
        is_dirty: true,
        open_buffers: [
          %{
            path: "lib/demo.ex",
            content: "defmodule Demo do\nend\n",
            dirty_content: "defmodule Demo do\n  # local edit\nend\n",
            dirty?: true
          }
        ],
        editor_lock: lock
      )

    document = LazyHTML.from_fragment(html)

    assert LazyHTML.query(
             document,
             "#editor-lock-ribbon[data-lock-state='foreign'][data-lock-resource='file']"
           )

    refute html =~ "run:coder-42"
    refute html =~ "hover:bg-rose-400/20"

    assert LazyHTML.query(document, "#code-editor-textarea[readonly][aria-readonly='true']")
    assert LazyHTML.query(document, "#save-file-btn[disabled]")
    assert LazyHTML.query(document, "#retry-file-lock-btn[phx-click='retry_file_lock']")

    assert document |> LazyHTML.query("#editor-lock-ribbon") |> LazyHTML.text() =~
             "Your unsaved buffer is safe"
  end

  test "file explorer stays editable when no conflict is supplied" do
    html =
      render_component(&WorkspaceComponents.file_explorer/1,
        files: ["lib/demo.ex"],
        selected_file: "lib/demo.ex",
        file_content: "editable\n",
        open_buffers: [
          %{
            path: "lib/demo.ex",
            content: "editable\n",
            dirty_content: "editable\n",
            dirty?: false
          }
        ],
        editor_lock: nil
      )

    document = LazyHTML.from_fragment(html)

    assert document |> LazyHTML.filter("#editor-lock-ribbon") |> Enum.empty?()
    assert document |> LazyHTML.filter("#code-editor-textarea[readonly]") |> Enum.empty?()
    assert document |> LazyHTML.filter("#save-file-btn[disabled]") |> Enum.empty?()
  end

  test "dirty editor controls keep accessible labels and AA token contrast in both themes" do
    document =
      render_component(&WorkspaceComponents.file_explorer/1,
        files: ["lib/demo.ex"],
        selected_file: "lib/demo.ex",
        file_content: "original\n",
        dirty_content: "dirty\n",
        is_dirty: true,
        open_buffers: [
          %{path: "lib/demo.ex", content: "original\n", dirty_content: "dirty\n", dirty?: true}
        ]
      )
      |> LazyHTML.from_fragment()

    assert LazyHTML.query(
             document,
             "#copy-file-btn[aria-label='Copy lib/demo.ex contents'][title='Copy file contents']"
           )

    assert LazyHTML.query(
             document,
             "#file-filter-input[aria-label='Filter retained project files']"
           )

    assert document
           |> LazyHTML.query("#file-filter-input")
           |> LazyHTML.attribute("class")
           |> Enum.any?(&String.contains?(&1, "text-sm"))

    save_classes =
      document
      |> LazyHTML.query("#save-file-btn")
      |> LazyHTML.attribute("class")
      |> Enum.join(" ")

    assert save_classes =~ "bg-[var(--sf-text-primary)]"
    assert save_classes =~ "text-[var(--sf-canvas-deep)]"

    for {theme, foreground, background} <- [
          {:dark, "#F4EFE7", "#101214"},
          {:light, "#202321", "#EAE5DC"}
        ] do
      assert contrast_ratio(foreground, background) >= 4.5, "#{theme} dirty Save contrast"
    end

    css = File.read!(Path.expand("../../../assets/css/app.css", __DIR__))
    refute css =~ "#file-explorer-container" <> " " <> "hover:bg-rose-400/20"
    assert css =~ ~s(#file-atlas-primary-field[data-files-focus-mode="true"] .sf-file-atlas-tree)
    assert css =~ "grid-template-columns: minmax(0, 1fr) minmax(10rem, 0.18fr)"
  end

  defp contrast_ratio(foreground, background) do
    {lighter, darker} =
      [relative_luminance(foreground), relative_luminance(background)]
      |> Enum.sort(:desc)
      |> List.to_tuple()

    (lighter + 0.05) / (darker + 0.05)
  end

  defp relative_luminance("#" <> rgb) do
    [r, g, b] =
      rgb
      |> String.codepoints()
      |> Enum.chunk_every(2)
      |> Enum.map(fn pair -> pair |> Enum.join() |> String.to_integer(16) |> Kernel./(255) end)
      |> Enum.map(fn value ->
        if value <= 0.04045, do: value / 12.92, else: :math.pow((value + 0.055) / 1.055, 2.4)
      end)

    0.2126 * r + 0.7152 * g + 0.0722 * b
  end
end
