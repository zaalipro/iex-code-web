defmodule IexCode.Runs.RunStepManifestTest do
  use IexCode.DataCase, async: false

  alias IexCode.{Projects, Repo, Runs, Sessions}
  alias IexCode.Runs.RunStep

  setup do
    root = Path.join(System.tmp_dir!(), "step-manifest-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    {:ok, project} = Projects.create_project(%{name: "Step manifest", root_path: root})
    {:ok, session} = Sessions.create_session(%{project_id: project.id, title: "Manifest"})

    {:ok, run} =
      Runs.create_run(%{
        project_id: project.id,
        session_id: session.id,
        objective: "Immutable step",
        kind: "analysis",
        mode: "single"
      })

    {:ok, step} =
      Runs.create_step(run, %{
        key: "read",
        kind: "read_file",
        title: "Read",
        position: 1,
        max_attempts: 2,
        depends_on: [],
        params: %{"path" => "README.md"},
        handler_version: 1,
        effect_class: "read",
        replay_policy: "safe",
        resource_spec: %{"contract" => "project_read_v1"},
        timeout_ms: 30_000
      })

    on_exit(fn -> File.rm_rf(root) end)
    %{run: run, step: step}
  end

  test "persisted step changesets reject every graph manifest field", %{step: step} do
    changes = %{
      parent_step_id: Ecto.UUID.generate(),
      key: "other",
      kind: "aggregate",
      title: "Other",
      position: 2,
      max_attempts: 3,
      depends_on: ["other"],
      params: %{"path" => "other"},
      handler_version: 2,
      effect_class: "native",
      replay_policy: "never",
      resource_spec: %{"contract" => "forged"},
      timeout_ms: 1
    }

    changeset = RunStep.changeset(step, changes)
    refute changeset.valid?

    for field <- Map.keys(changes) do
      assert {"cannot be changed after creation", _} = changeset.errors[field]
    end

    assert {:error, %Ecto.Changeset{}} = Repo.update(changeset)
    assert Repo.get!(RunStep, step.id) == step
  end

  test "transition API cannot smuggle graph changes with lifecycle updates", %{step: step} do
    assert {:error, %Ecto.Changeset{} = changeset} =
             Runs.transition_step(step, "running", %{
               kind: "aggregate",
               params: %{},
               progress: 10
             })

    assert changeset.errors[:kind]
    assert changeset.errors[:params]
    persisted = Repo.get!(RunStep, step.id)
    assert persisted.status == "pending"
    assert persisted.progress == 0
    assert persisted.kind == "read_file"
  end
end
