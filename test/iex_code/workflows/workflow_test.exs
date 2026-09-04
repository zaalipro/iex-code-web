defmodule IexCode.Workflows.WorkflowTest do
  use IexCode.DataCase

  alias IexCode.Projects.Project
  alias IexCode.Workflows
  alias IexCode.Workflows.{Workflow, WorkflowRun}

  defp create_project do
    root = "/tmp/test_project_#{System.unique_integer([:positive])}"
    File.mkdir_p!(root)

    %Project{}
    |> Project.changeset(%{
      name: "Test Project",
      root_path: root,
      description: "A test project"
    })
    |> Repo.insert!()
  end

  defp valid_steps do
    [
      %{
        "key" => "research",
        "kind" => "deep_research",
        "title" => "Deep Research",
        "depends_on" => [],
        "params" => %{"query" => "Elixir OTP design"},
        "model_config" => %{"reasoning_effort" => "high"},
        "safety_policy" => "read_only"
      },
      %{
        "key" => "code_gen",
        "kind" => "swarm_code_gen",
        "title" => "Swarm Code Gen",
        "depends_on" => ["research"],
        "params" => %{"prompt" => "Implement OTP GenServer"},
        "model_config" => %{"reasoning_effort" => "medium"},
        "safety_policy" => "full_auto"
      }
    ]
  end

  describe "workflows schema and context CRUD" do
    test "creates workflow and auto-generates slug from name" do
      project = create_project()

      attrs = %{
        project_id: project.id,
        name: "Full Autonomous Pipeline",
        description: "Autonomous end-to-end coding pipeline",
        tags: ["autonomous", "ci"],
        steps: valid_steps()
      }

      assert {:ok, %Workflow{} = workflow} = Workflows.create_workflow(attrs)
      assert workflow.slug == "full-autonomous-pipeline"
      assert workflow.version == 1
      assert workflow.is_active == true
      assert length(workflow.steps) == 2

      # Query by id and by slug
      assert fetched = Workflows.get_workflow!(workflow.id)
      assert fetched.id == workflow.id

      assert by_slug = Workflows.get_workflow_by_slug(project.id, "full-autonomous-pipeline")
      assert by_slug.id == workflow.id
    end

    test "rejects workflow with invalid DAG steps" do
      project = create_project()

      invalid_attrs = %{
        project_id: project.id,
        name: "Bad Pipeline",
        slug: "bad-pipeline",
        steps: [
          %{"key" => "A", "kind" => "deep_research", "depends_on" => ["B"]},
          %{"key" => "B", "kind" => "swarm_code_gen", "depends_on" => ["A"]}
        ]
      }

      assert {:error, changeset} = Workflows.create_workflow(invalid_attrs)
      assert changeset.errors[:steps] != nil
    end

    test "updates and deletes workflow" do
      project = create_project()

      {:ok, workflow} =
        Workflows.create_workflow(%{
          project_id: project.id,
          name: "Original Name",
          steps: valid_steps()
        })

      assert {:ok, updated} =
               Workflows.update_workflow(workflow, %{name: "Updated Name", is_active: false})

      assert updated.name == "Updated Name"
      assert updated.is_active == false

      assert {:ok, _deleted} = Workflows.delete_workflow(updated)
      assert Workflows.get_workflow(workflow.id) == nil
    end

    test "lists workflows with filters" do
      project = create_project()

      {:ok, _w1} =
        Workflows.create_workflow(%{
          project_id: project.id,
          name: "Active One",
          is_active: true,
          steps: valid_steps()
        })

      {:ok, _w2} =
        Workflows.create_workflow(%{
          project_id: project.id,
          name: "Inactive Two",
          is_active: false,
          steps: valid_steps()
        })

      all = Workflows.list_workflows(project.id)
      assert length(all) == 2

      active = Workflows.list_workflows(project.id, active_only: true)
      assert length(active) == 1
      assert hd(active).name == "Active One"
    end
  end

  describe "workflow_runs schema and lifecycle" do
    test "creates and updates workflow runs through valid lifecycle states" do
      project = create_project()

      {:ok, workflow} =
        Workflows.create_workflow(%{
          project_id: project.id,
          name: "Runnable Workflow",
          steps: valid_steps()
        })

      assert {:ok, %WorkflowRun{} = run} =
               Workflows.create_run(workflow, %{
                 project_id: project.id,
                 status: "pending",
                 progress: 0,
                 inputs: %{"feature" => "Auth"}
               })

      assert run.status == "pending"
      assert run.progress == 0
      assert run.workflow_id == workflow.id

      # Transition to running
      assert {:ok, running_run} =
               Workflows.update_run(run, %{
                 status: "running",
                 progress: 50,
                 started_at: DateTime.utc_now()
               })

      assert running_run.status == "running"
      assert running_run.progress == 50

      # Transition to completed
      assert {:ok, completed_run} =
               Workflows.update_run(running_run, %{
                 status: "completed",
                 progress: 100,
                 completed_at: DateTime.utc_now()
               })

      assert completed_run.status == "completed"
      assert completed_run.progress == 100

      # List runs
      runs = Workflows.list_runs(project.id)
      assert length(runs) == 1
    end
  end

  describe "synthesize_workflow_from_prompt/3" do
    test "generates valid 5-step DAG blueprint from prompt" do
      project = create_project()

      blueprint =
        Workflows.synthesize_workflow_from_prompt(
          "Build OAuth2 Authentication with PKCE verification",
          project.id
        )

      assert blueprint["project_id"] == project.id
      assert blueprint["slug"] != ""
      assert length(blueprint["steps"]) == 5

      # Verify the generated steps form a valid DAG
      assert :ok =
               IexCode.Workflows.WorkflowDag.validate(blueprint["steps"], blueprint["variables"])

      # Verify it can be inserted into the database cleanly
      assert {:ok, %Workflow{} = workflow} = Workflows.create_workflow(blueprint)
      assert workflow.name != ""
      assert length(workflow.steps) == 5
    end
  end
end
