defmodule IexCode.Engine.AgentWorkspaceLockTest do
  use IexCode.DataCase, async: false

  alias IexCode.{Projects, Sessions, WorkspaceLocks}
  alias IexCode.Engine.Agents.{CoderAgent, VerifierAgent}

  setup do
    root =
      Path.join(System.tmp_dir!(), "iex-code-agent-lock-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(root, "lib"))
    File.write!(Path.join(root, "lib/demo.ex"), "defmodule Demo, do: :original\n")

    {:ok, project} = Projects.create_project(%{name: "Agent lock test", root_path: root})
    {:ok, session} = Sessions.create_session(%{project_id: project.id, title: "Agent lock"})

    on_exit(fn -> File.rm_rf(root) end)
    %{project: project, root: root, session: session}
  end

  test "CoderAgent ignores a caller-supplied project id and cannot bypass a file lock", %{
    project: project,
    root: root,
    session: session
  } do
    pid =
      start_supervised!(
        {CoderAgent, session_id: session.id, session: session, project_root: root}
      )

    Ecto.Adapters.SQL.Sandbox.allow(IexCode.Repo, self(), pid)

    assert {:ok, blocker} =
             WorkspaceLocks.acquire(project, [{{:file, "lib/demo.ex"}, :write}],
               owner_id: "test:coder-blocker"
             )

    on_exit(fn -> WorkspaceLocks.release(blocker) end)

    assert {:error, {:workspace_lock_waiting, _locks}} =
             CoderAgent.apply_patches(
               session.id,
               [
                 %{
                   path: "lib/demo.ex",
                   target: ":original",
                   replacement: ":changed"
                 }
               ],
               project_root: root,
               project_id: Ecto.UUID.generate()
             )

    assert File.read!(Path.join(root, "lib/demo.ex")) ==
             "defmodule Demo, do: :original\n"
  end

  test "VerifierAgent derives project identity from its session before running tests", %{
    project: project,
    root: root,
    session: session
  } do
    pid =
      start_supervised!(
        {VerifierAgent, session_id: session.id, session: session, project_root: root}
      )

    Ecto.Adapters.SQL.Sandbox.allow(IexCode.Repo, self(), pid)

    assert {:ok, blocker} =
             WorkspaceLocks.acquire(project, [{:project, :exclusive}],
               owner_id: "test:verifier-blocker"
             )

    on_exit(fn -> WorkspaceLocks.release(blocker) end)

    assert {:error, {:workspace_lock_waiting, _locks}} =
             VerifierAgent.run_tests(session.id,
               project_root: root,
               project_id: Ecto.UUID.generate()
             )

    refute File.exists?(Path.join(root, "_build"))
  end
end
