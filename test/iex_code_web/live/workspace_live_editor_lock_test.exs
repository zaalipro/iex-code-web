defmodule IexCodeWeb.WorkspaceLiveEditorLockTest do
  use IexCode.E2E.Case, async: false

  @moduletag mock_llm: true

  alias IexCode.{Runs, WorkspaceLocks}

  test "foreign file lock makes the editor read-only and a server save preserves the buffer", %{
    conn: conn,
    workspace_path: root
  } do
    original = "defmodule LockedFile, do: :original\n"
    edited = "defmodule LockedFile, do: :edited\n"
    workspace_write_file(root, "lib/locked_file.ex", original)

    project = create_project_fixture(%{root_path: root})
    session = create_session_fixture(project)

    {:ok, blocker} =
      WorkspaceLocks.acquire(project, [{{:file, "lib/locked_file.ex"}, :write}],
        owner_id: "run:foreign-editor-owner"
      )

    on_exit(fn -> WorkspaceLocks.release(blocker) end)

    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
    render_click(view, "select_file", %{"path" => "lib/locked_file.ex"})

    assert has_element?(view, "#editor-lock-ribbon")
    refute render(view) =~ "run:foreign-editor-owner"
    assert has_element?(view, "#code-editor-textarea[readonly][aria-readonly='true']")
    assert has_element?(view, "#save-file-btn[disabled]")
    assert has_element?(view, "#retry-file-lock-btn")

    # Disabled controls are advisory only. A forged event must hit the same
    # server-side lock gate and retain the precise submitted buffer.
    render_click(view, "save_file", %{"content" => edited})

    assert File.read!(Path.join(root, "lib/locked_file.ex")) == original
    document = view |> render() |> LazyHTML.from_fragment()

    assert document |> LazyHTML.query("#code-editor-textarea") |> LazyHTML.text() =~
             "defmodule LockedFile, do: :edited"

    assert has_element?(view, "#editor-lock-ribbon")
    assert render(view) =~ "Your changes are still in the editor"
    assert render(view) =~ "Unsaved changes"
    assert has_element?(view, "#files-buffer-signal", "Unsaved changes")

    render_click(view, "toggle_files_focus_mode")
    assert has_element?(view, "#files-focus-mode-toggle[aria-pressed='true']")
    assert has_element?(view, "#editor-lock-ribbon")
    assert has_element?(view, "#code-editor-textarea[readonly]")
    assert has_element?(view, "#save-file-btn[disabled]")
    assert has_element?(view, "#retry-file-lock-btn")
  end

  test "retry reflects release and a subsequent save acquires and releases a short file lock", %{
    conn: conn,
    workspace_path: root
  } do
    original = "original\n"
    edited = "saved after retry\n"
    workspace_write_file(root, "lib/retry.ex", original)

    project = create_project_fixture(%{root_path: root})
    session = create_session_fixture(project)

    {:ok, blocker} =
      WorkspaceLocks.acquire(project, [:project], owner_id: "run:project-owner")

    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
    render_click(view, "select_file", %{"path" => "lib/retry.ex"})

    assert has_element?(view, "#editor-lock-ribbon[data-lock-resource='project']")

    assert :ok = WorkspaceLocks.release(blocker)
    render_click(view, "retry_file_lock")

    refute has_element?(view, "#editor-lock-ribbon")
    refute has_element?(view, "#save-file-btn[disabled]")
    assert render(view) =~ "The file is available"

    render_click(view, "save_file", %{"content" => edited})

    assert File.read!(Path.join(root, "lib/retry.ex")) == edited

    assert [] ==
             Runs.list_workspace_locks(
               project_id: project.id,
               owner_id: "session:#{session.id}",
               active: true
             )

    assert render(view) =~ "Saved lib/retry.ex"
    refute render(view) =~ "Unsaved Changes"
  end

  test "save resolves the selected path again and rejects a symlink escape without losing edits",
       %{
         conn: conn,
         workspace_path: root
       } do
    outside =
      Path.join(
        System.tmp_dir!(),
        "iex-code-editor-outside-#{System.unique_integer([:positive, :monotonic])}.txt"
      )

    File.write!(outside, "outside\n")
    workspace_write_file(root, "safe.txt", "inside\n")
    on_exit(fn -> File.rm(outside) end)

    project = create_project_fixture(%{root_path: root})
    session = create_session_fixture(project)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    render_click(view, "select_file", %{"path" => "safe.txt"})
    File.rm!(Path.join(root, "safe.txt"))
    File.ln_s!(outside, Path.join(root, "safe.txt"))

    html = render_click(view, "save_file", %{"content" => "must not escape\n"})

    assert html =~ "invalid file path"
    assert html =~ "Your changes are still in the editor"
    assert html =~ "must not escape"
    assert File.read!(outside) == "outside\n"
  end

  test "foreign project lock prevents a forged file revert event", %{
    conn: conn,
    workspace_path: root
  } do
    init_git_workspace(root)
    workspace_write_file(root, "lib/revert_target.ex", "defmodule RevertTarget, do: :original\n")
    git!(root, ["add", "."])
    git!(root, ["commit", "-m", "initial"])

    edited = "defmodule RevertTarget, do: :keep_my_edit\n"
    workspace_write_file(root, "lib/revert_target.ex", edited)

    project = create_project_fixture(%{root_path: root})
    session = create_session_fixture(project)

    {:ok, blocker} =
      WorkspaceLocks.acquire(project, [:project], owner_id: "run:foreign-file-effect")

    on_exit(fn -> WorkspaceLocks.release(blocker) end)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
    render_click(view, "switch_tab", %{"tab" => "changes"})

    render_click(view, "request_revert_git_file", %{
      "file" => "lib/revert_target.ex",
      "scope" => "unstaged",
      "source" => "ledger"
    })

    html = render_click(view, "revert_file", %{})

    assert File.read!(Path.join(root, "lib/revert_target.ex")) == edited
    assert html =~ "Workspace change blocked by another IexCode task"
    refute html =~ "run:foreign-file-effect"
    assert html =~ "no UI state was discarded"
  end

  test "foreign file lock prevents a forged Git staging event", %{
    conn: conn,
    workspace_path: root
  } do
    init_git_workspace(root)
    workspace_write_file(root, "lib/stage_target.ex", "defmodule StageTarget, do: :original\n")
    git!(root, ["add", "."])
    git!(root, ["commit", "-m", "initial"])
    workspace_write_file(root, "lib/stage_target.ex", "defmodule StageTarget, do: :edited\n")

    project = create_project_fixture(%{root_path: root})
    session = create_session_fixture(project)

    {:ok, blocker} =
      WorkspaceLocks.acquire(project, [{{:file, "lib/stage_target.ex"}, :write}],
        owner_id: "run:foreign-git-effect"
      )

    on_exit(fn -> WorkspaceLocks.release(blocker) end)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
    render_click(view, "switch_tab", %{"tab" => "changes"})

    html = render_click(view, "stage_file", %{"file" => "lib/stage_target.ex"})

    assert git!(root, ["diff", "--cached", "--name-only"]) == ""
    assert html =~ "Workspace change blocked by another IexCode task"
    refute html =~ "run:foreign-git-effect"
  end

  defp init_git_workspace(root) do
    git!(root, ["init", "-b", "main"])
    git!(root, ["config", "user.name", "Workspace Lock Test"])
    git!(root, ["config", "user.email", "workspace-lock@example.test"])
  end

  defp git!(root, args) do
    {output, 0} = System.cmd("git", args, cd: root, stderr_to_stdout: true)
    String.trim(output)
  end
end
