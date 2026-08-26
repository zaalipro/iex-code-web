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

    assert LazyHTML.query(document, "#code-editor-textarea[readonly][aria-readonly='true']")
    assert LazyHTML.query(document, "#save-file-btn[disabled]")
    assert LazyHTML.query(document, "#retry-file-lock-btn[phx-click='retry_file_lock']")

    assert document |> LazyHTML.query("#editor-lock-ribbon") |> LazyHTML.text() =~
             "Your unsaved buffer is safe"
  end

  test "file explorer stays editable when no conflict is supplied" do
    document =
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
      |> LazyHTML.from_fragment()

    assert document |> LazyHTML.filter("#editor-lock-ribbon") |> Enum.empty?()
    assert document |> LazyHTML.filter("#code-editor-textarea[readonly]") |> Enum.empty?()
    assert document |> LazyHTML.filter("#save-file-btn[disabled]") |> Enum.empty?()
  end
end
