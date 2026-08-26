defmodule IexCode.Tools.MutationSnapshotTest do
  use IexCode.DataCase, async: false

  alias IexCode.Tools.MultiPatch
  alias IexCode.Tools.MultiPatch.Snapshot
  alias IexCode.{Projects, Runs, Sessions}
  alias IexCode.Engine.SwarmCoordinator

  setup do
    root = Path.join(System.tmp_dir!(), "iex_code_snapshot_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "lib"))
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root}
  end

  test "rollback manifest survives loss of the ETS hot cache", %{root: root} do
    path = Path.join(root, "lib/durable.ex")
    original = "defmodule Durable do\n  def value, do: :before\nend\n"
    File.write!(path, original)

    {:ok, summary} =
      MultiPatch.apply_patches(
        root,
        [%{path: "lib/durable.ex", target: ":before", replacement: ":after"}],
        session_id: "durable-session"
      )

    assert File.read!(path) =~ ":after"
    :ets.delete_all_objects(Snapshot.table_name())

    assert {:ok, persisted} = Snapshot.get_snapshot(summary.transaction_id)
    assert persisted.session_id == "durable-session"
    assert persisted.project_root == root

    assert {:ok, %{restored_files: ["lib/durable.ex"]}} =
             MultiPatch.rollback(summary.transaction_id)

    assert File.read!(path) == original
    assert {:error, :not_found} = Snapshot.get_snapshot(summary.transaction_id)
  end

  test "snapshot persistence fails closed before populating the hot cache", %{root: root} do
    path = Path.join(root, "lib/fail_closed.ex")
    File.write!(path, "before")
    transaction_id = String.duplicate("x", 201)

    patch = %{
      path: "lib/fail_closed.ex",
      full_path: path,
      file_existed?: true,
      original_content: "before",
      new_content: "after"
    }

    assert {:error, %Ecto.Changeset{}} =
             Snapshot.save_snapshot(transaction_id, [patch], project_root: root)

    assert [] = :ets.lookup(Snapshot.table_name(), transaction_id)
    assert File.read!(path) == "before"
  end

  test "rollback re-authorizes durable paths against their workspace", %{root: root} do
    outside = Path.join(Path.dirname(root), "outside_#{System.unique_integer([:positive])}.txt")
    File.write!(outside, "after")
    on_exit(fn -> File.rm(outside) end)
    transaction_id = "tampered-#{System.unique_integer([:positive])}"

    patch = %{
      path: outside,
      full_path: outside,
      file_existed?: true,
      original_content: "before",
      new_content: "after"
    }

    assert :ok = Snapshot.save_snapshot(transaction_id, [patch], project_root: root)
    assert {:error, {:partial, %{failed_files: [^outside]}}} = MultiPatch.rollback(transaction_id)
    assert File.read!(outside) == "after"
    Snapshot.delete_snapshot(transaction_id)
  end

  test "durable run ownership isolates rollback within one legacy session", %{root: root} do
    {:ok, project} = Projects.create_project(%{name: "Snapshot scope", root_path: root})
    {:ok, session} = Sessions.create_session(%{project_id: project.id, title: "Shared session"})

    {:ok, first_run} =
      Runs.create_run(%{
        project_id: project.id,
        session_id: session.id,
        objective: "First durable mutation"
      })

    {:ok, second_run} =
      Runs.create_run(%{
        project_id: project.id,
        session_id: session.id,
        objective: "Second durable mutation"
      })

    first = Path.join(root, "lib/first.txt")
    second = Path.join(root, "lib/second.txt")
    interactive = Path.join(root, "lib/interactive.txt")
    File.write!(first, "first-before")
    File.write!(second, "second-before")
    File.write!(interactive, "interactive-before")

    assert {:ok, first_summary} =
             MultiPatch.apply_patches(
               root,
               [%{path: "lib/first.txt", target: "first-before", replacement: "first-after"}],
               session_id: session.id,
               run_id: first_run.id
             )

    assert {:ok, second_summary} =
             MultiPatch.apply_patches(
               root,
               [%{path: "lib/second.txt", target: "second-before", replacement: "second-after"}],
               session_id: session.id,
               run_id: second_run.id
             )

    assert {:ok, interactive_summary} =
             MultiPatch.apply_patches(
               root,
               [
                 %{
                   path: "lib/interactive.txt",
                   target: "interactive-before",
                   replacement: "interactive-after"
                 }
               ],
               session_id: session.id
             )

    assert [owned] = Snapshot.list_run_snapshots(first_run.id)
    assert owned.transaction_id == first_summary.transaction_id
    assert [legacy] = Snapshot.list_snapshots(session.id)
    assert legacy.transaction_id == interactive_summary.transaction_id

    state = %SwarmCoordinator.State{session_id: session.id, run_id: first_run.id}
    assert {:ok, :rolled_back} = SwarmCoordinator.perform_rollback(root, state)
    assert File.read!(first) == "first-before"
    assert File.read!(second) == "second-after"
    assert File.read!(interactive) == "interactive-after"

    assert {:ok, _} = MultiPatch.rollback(second_summary.transaction_id)
    assert {:ok, _} = MultiPatch.rollback(interactive_summary.transaction_id)
  end
end
