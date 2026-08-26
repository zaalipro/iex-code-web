defmodule IexCode.ToolsWorkspaceLocksTest do
  use IexCode.DataCase, async: false

  alias IexCode.{Projects, Runs, Sessions, Tools, WorkspaceLocks}
  alias IexCode.Tools.TerminalServer

  setup do
    root =
      Path.join(System.tmp_dir!(), "iex-code-tools-lock-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(root, "lib"))
    File.write!(Path.join(root, "lib/demo.ex"), "defmodule Demo, do: :original\n")

    {:ok, project} =
      Projects.create_project(%{name: "Tools lock test", root_path: root})

    {:ok, session} =
      Sessions.create_session(%{project_id: project.id, title: "Tools lock session"})

    on_exit(fn -> File.rm_rf(root) end)
    %{project: project, root: root, session: session}
  end

  test "file conflicts prevent write, patch, and multi-patch side effects", %{
    project: project,
    root: root
  } do
    assert {:ok, blocker} =
             WorkspaceLocks.acquire(
               project,
               [{{:file, "lib/demo.ex"}, :write}],
               owner_id: "test:blocker"
             )

    on_exit(fn -> WorkspaceLocks.release(blocker) end)

    args = %{
      "path" => "lib/demo.ex",
      "content" => "defmodule Demo, do: :overwritten\n",
      "project_id" => project.id
    }

    assert {:error, {:workspace_lock_waiting, locks}} =
             Tools.execute("write_file", args, root)

    assert Enum.all?(locks, &(&1.status == "waiting"))

    assert {:error, {:workspace_lock_waiting, _locks}} =
             Tools.execute(
               "patch_file",
               %{
                 "path" => "lib/demo.ex",
                 "target_content" => ":original",
                 "replacement_content" => ":patched",
                 "project_id" => project.id
               },
               root
             )

    assert {:error, {:workspace_lock_waiting, _locks}} =
             Tools.execute(
               "multi_patch",
               %{
                 "patches" => [
                   %{
                     "path" => "lib/demo.ex",
                     "target_content" => ":original",
                     "replacement_content" => ":patched"
                   }
                 ],
                 "project_id" => project.id
               },
               root
             )

    assert File.read!(Path.join(root, "lib/demo.ex")) ==
             "defmodule Demo, do: :original\n"
  end

  test "project conflicts prevent an arbitrary command from starting", %{
    project: project,
    root: root
  } do
    assert {:ok, blocker} =
             WorkspaceLocks.acquire(project, [{:project, :exclusive}],
               owner_id: "test:project-blocker"
             )

    on_exit(fn -> WorkspaceLocks.release(blocker) end)
    sentinel = Path.join(root, "command-side-effect.txt")

    assert {:error, {:workspace_lock_waiting, _locks}} =
             Tools.execute(
               "run_command",
               %{
                 "command" => "printf MUTATED > command-side-effect.txt",
                 "project_id" => project.id,
                 "timeout_ms" => 50
               },
               root
             )

    refute File.exists?(sentinel)
  end

  test "a trusted project id fails closed when paired with another root", %{
    project: project,
    root: root
  } do
    other_root = root <> "-other"
    File.mkdir_p!(other_root)
    on_exit(fn -> File.rm_rf(other_root) end)

    assert {:error, :project_workspace_mismatch} =
             Tools.execute(
               "write_file",
               %{
                 "path" => "escape.txt",
                 "content" => "must not be written",
                 "project_id" => project.id
               },
               other_root
             )

    refute File.exists?(Path.join(other_root, "escape.txt"))
  end

  test "git conflicts prevent index mutation", %{project: project, root: root} do
    {_, 0} = System.cmd("git", ["init"], cd: root, stderr_to_stdout: true)

    assert {:ok, blocker} =
             WorkspaceLocks.acquire(project, [{:git, :exclusive}], owner_id: "test:git-blocker")

    on_exit(fn -> WorkspaceLocks.release(blocker) end)

    assert {:error, {:workspace_lock_waiting, _locks}} =
             Tools.execute(
               "git_stage",
               %{"files" => ["lib/demo.ex"], "project_id" => project.id},
               root
             )

    {staged, 0} = System.cmd("git", ["diff", "--cached", "--name-only"], cd: root)
    assert staged == ""
  end

  test "run command borrows a dispatcher-style outer capability without self-conflict", %{
    project: project,
    root: root,
    session: session
  } do
    {:ok, run} =
      Runs.create_run(%{
        project_id: project.id,
        session_id: session.id,
        objective: "Verify nested tool delegation",
        kind: "coding_swarm",
        mode: "swarm"
      })

    identity = [
      owner_id: "run:#{run.id}",
      project_id: project.id,
      run_id: run.id,
      session_id: session.id
    ]

    assert {:ok, outer} =
             WorkspaceLocks.acquire(project, [{:project, :exclusive}], identity)

    on_exit(fn ->
      TerminalServer.kill(session.id)
      WorkspaceLocks.release(outer)
    end)

    assert {:ok, output} =
             WorkspaceLocks.with_delegation(outer, fn ->
               Tools.execute(
                 "run_command",
                 %{
                   "command" => "printf nested-delegation-ok",
                   "project_id" => project.id,
                   "run_id" => run.id,
                   "session_id" => session.id
                 },
                 root
               )
             end)

    assert output =~ "nested-delegation-ok"
  end

  test "a fake PTY routing id is not persisted as a workspace-lock session foreign key", %{
    root: root
  } do
    terminal_id = "terminal-only-#{System.unique_integer([:positive])}"
    on_exit(fn -> TerminalServer.kill(terminal_id) end)

    assert {:ok, output} =
             Tools.execute(
               "run_command",
               %{
                 "command" => "printf terminal-routing-ok",
                 "session_id" => terminal_id
               },
               root
             )

    assert output =~ "terminal-routing-ok"
  end

  test "a run id cannot be borrowed without its persisted matching session", %{
    project: project,
    root: root,
    session: session
  } do
    {:ok, run} =
      Runs.create_run(%{
        project_id: project.id,
        session_id: session.id,
        objective: "Trusted lock identity",
        kind: "coding_swarm",
        mode: "swarm"
      })

    assert {:ok, blocker} =
             WorkspaceLocks.acquire(project, [{{:file, "lib/demo.ex"}, :write}],
               owner_id: "test:identity-blocker"
             )

    on_exit(fn -> WorkspaceLocks.release(blocker) end)

    assert {:error, {:workspace_lock_waiting, [waiting]}} =
             Tools.execute(
               "write_file",
               %{
                 "path" => "lib/demo.ex",
                 "content" => "must not change",
                 "project_id" => project.id,
                 "run_id" => run.id,
                 "session_id" => "fake-routing-session"
               },
               root
             )

    assert is_nil(waiting.run_id)
    assert is_nil(waiting.session_id)
    refute waiting.owner_id == "run:#{run.id}"
  end
end
