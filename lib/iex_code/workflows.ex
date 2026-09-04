defmodule IexCode.Workflows do
  @moduledoc """
  Context API for durable Workflows and Workflow Runs.
  Provides persistence, querying, DAG launching, and execution controls.
  """

  import Ecto.Query, warn: false
  alias IexCode.Repo
  alias IexCode.Workflows.{Engine, VariableInterpolator, Workflow, WorkflowDag, WorkflowRun}

  @pubsub IexCode.PubSub

  # Workflows CRUD

  @doc "Lists workflows for a project."
  def list_workflows(project_id, opts \\ []) do
    query =
      from w in Workflow,
        where: w.project_id == ^project_id,
        order_by: [desc: w.inserted_at]

    query =
      if Keyword.get(opts, :active_only, false) do
        from w in query, where: w.is_active == true
      else
        query
      end

    Repo.retry_on_busy(fn -> Repo.all(query) end)
  end

  @doc "Gets a single workflow by ID, raising if not found."
  def get_workflow!(id) do
    Repo.retry_on_busy(fn ->
      Repo.get!(Workflow, id)
      |> Repo.preload([:project, :runs])
    end)
  end

  @doc "Gets a single workflow by ID, returning nil if not found."
  def get_workflow(id) do
    Repo.retry_on_busy(fn ->
      case Repo.get(Workflow, id) do
        nil -> nil
        w -> Repo.preload(w, [:project, :runs])
      end
    end)
  end

  @doc "Gets a workflow by project ID and slug."
  def get_workflow_by_slug(project_id, slug) do
    query =
      from w in Workflow,
        where: w.project_id == ^project_id and w.slug == ^slug

    Repo.retry_on_busy(fn ->
      case Repo.one(query) do
        nil -> nil
        w -> Repo.preload(w, [:project, :runs])
      end
    end)
  end

  @doc "Creates a new workflow."
  def create_workflow(attrs) do
    Repo.retry_on_busy(fn ->
      %Workflow{}
      |> Workflow.changeset(attrs)
      |> Repo.insert()
    end)
    |> case do
      {:ok, workflow} ->
        broadcast_workflow(workflow, {:workflow_created, workflow})
        {:ok, workflow}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc "Updates a workflow."
  def update_workflow(%Workflow{} = workflow, attrs) do
    Repo.retry_on_busy(fn ->
      workflow
      |> Workflow.changeset(attrs)
      |> Repo.update()
    end)
    |> case do
      {:ok, updated} ->
        broadcast_workflow(updated, {:workflow_updated, updated})
        {:ok, updated}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc "Deletes a workflow."
  def delete_workflow(%Workflow{} = workflow) do
    Repo.retry_on_busy(fn -> Repo.delete(workflow) end)
    |> case do
      {:ok, deleted} ->
        broadcast_workflow(deleted, {:workflow_deleted, deleted.id})
        {:ok, deleted}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc "Returns a workflow changeset for tracking changes."
  def change_workflow(%Workflow{} = workflow, attrs \\ %{}) do
    Workflow.changeset(workflow, attrs)
  end

  # Workflow Runs

  @doc "Lists runs for a project or workflow."
  def list_runs(scope_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    query =
      from r in WorkflowRun,
        where: r.workflow_id == ^scope_id or r.project_id == ^scope_id,
        order_by: [desc: r.inserted_at],
        limit: ^limit,
        preload: [:workflow]

    Repo.retry_on_busy(fn -> Repo.all(query) end)
  end

  @doc "Gets a single workflow run by ID, raising if not found."
  def get_run!(id) do
    Repo.retry_on_busy(fn ->
      Repo.get!(WorkflowRun, id)
      |> Repo.preload([:workflow, :project, :session])
    end)
  end

  @doc "Gets a single workflow run by ID, returning nil if not found."
  def get_run(id) do
    Repo.retry_on_busy(fn ->
      case Repo.get(WorkflowRun, id) do
        nil -> nil
        r -> Repo.preload(r, [:workflow, :project, :session])
      end
    end)
  end

  @doc "Creates a new workflow run record."
  def create_run(%Workflow{} = workflow, attrs) do
    attrs =
      attrs
      |> Map.put(:workflow_id, workflow.id)
      |> Map.put_new(:project_id, workflow.project_id)
      |> Map.put_new(:resolved_steps, workflow.steps)

    Repo.retry_on_busy(fn ->
      %WorkflowRun{}
      |> WorkflowRun.changeset(attrs)
      |> Repo.insert()
    end)
  end

  @doc "Updates a workflow run record."
  def update_run(%WorkflowRun{} = run, attrs) do
    Repo.retry_on_busy(fn ->
      run
      |> WorkflowRun.changeset(attrs)
      |> Repo.update()
    end)
  end

  # Launch & Orchestration

  @doc """
  Launches an execution run for a given workflow.
  Merges provided inputs with variable defaults, interpolates initial parameters,
  persists the WorkflowRun record, and launches the execution engine GenServer.
  """
  def launch_workflow(workflow_or_id, inputs \\ %{}, opts \\ [])

  def launch_workflow(%Workflow{} = workflow, inputs, opts) do
    workflow = Repo.preload(workflow, [:project])

    raw_variables =
      Map.get(workflow, :variables_schema) || Map.get(workflow, :variables) || []

    inputs_map = if is_map(inputs), do: inputs, else: Enum.into(inputs || [], %{})

    case validate_required_variables(raw_variables, inputs_map) do
      :ok ->
        resolved_inputs = resolve_workflow_inputs(raw_variables, inputs_map)

        # Context for initial step interpolation
        interp_context = %{
          "inputs" => resolved_inputs,
          "project" => %{
            "id" => workflow.project_id,
            "name" => if(workflow.project, do: workflow.project.name, else: ""),
            "root_path" => if(workflow.project, do: workflow.project.root_path, else: File.cwd!())
          }
        }

        resolved_steps =
          Enum.map(workflow.steps || [], fn step ->
            case VariableInterpolator.interpolate(step, interp_context) do
              {:ok, s} -> s
              _ -> step
            end
          end)

        initial_step_states =
          Map.new(resolved_steps, fn step ->
            {WorkflowDag.step_key(step), %{"status" => "pending"}}
          end)

        run_attrs = %{
          workflow_id: workflow.id,
          project_id: workflow.project_id,
          session_id: Keyword.get(opts, :session_id),
          status: "pending",
          progress: 0,
          inputs: resolved_inputs,
          resolved_steps: resolved_steps,
          step_states: initial_step_states,
          metadata: Keyword.get(opts, :metadata, %{})
        }

        with {:ok, run} <- create_run(workflow, run_attrs) do
          # Start execution engine asynchronously unless requested otherwise
          async =
            Keyword.get(
              opts,
              :async,
              Application.get_env(:iex_code, :workflow_engine_async, true)
            )

          if async do
            case Engine.start_run(run.id) do
              {:ok, _pid} ->
                :ok

              {:error, reason} ->
                update_run(run, %{
                  status: "failed",
                  error_message: "Failed to start engine: #{inspect(reason)}"
                })
            end
          end

          broadcast_run(run, {:workflow_run_launched, run})
          {:ok, run}
        end

      {:error, missing} ->
        {:error, {:missing_required_variables, missing}}
    end
  end

  def launch_workflow(id, inputs, opts) when is_binary(id) do
    case get_workflow(id) do
      nil -> {:error, :workflow_not_found}
      workflow -> launch_workflow(workflow, inputs, opts)
    end
  end

  # Interactive Run Controls

  @doc "Pauses an active workflow run."
  def pause_run(run_id) do
    Engine.pause_run(run_id)
  end

  @doc "Resumes a paused workflow run."
  def resume_run(run_id) do
    Engine.resume_run(run_id)
  end

  @doc "Cancels an active workflow run."
  def cancel_run(run_id) do
    Engine.cancel_run(run_id)
  end

  @doc "Retries a specific failed step in a workflow run."
  def retry_step(run_id, step_key, opts \\ []) do
    case Engine.whereis_run(run_id) do
      nil ->
        case get_run(run_id) do
          nil ->
            {:error, :run_not_found}

          run ->
            step_state = Map.get(run.step_states || %{}, step_key, %{})

            if run.status in ["failed", "paused", "cancelled", :failed, :paused, :cancelled] or
                 Map.get(step_state, "status") in ["failed", "cancelled"] do
              new_step_states =
                Map.update(run.step_states || %{}, step_key, %{"status" => "pending"}, fn s ->
                  Map.put(s, "status", "pending")
                end)

              {:ok, updated_run} =
                update_run(run, %{
                  status: "running",
                  error_message: nil,
                  step_states: new_step_states
                })

              broadcast_run(updated_run, {:step_state_updated, run.id, step_key, "pending"})
              broadcast_run(updated_run, {:workflow_run_updated, updated_run})

              async =
                Keyword.get(
                  opts,
                  :async,
                  Application.get_env(:iex_code, :workflow_engine_async, true)
                )

              if async do
                case Engine.start_run(run.id) do
                  {:ok, _pid} ->
                    {:ok, updated_run}

                  {:error, reason} ->
                    {:error, reason}
                end
              else
                {:ok, updated_run}
              end
            else
              {:error, :run_not_active}
            end
        end

      _pid ->
        Engine.retry_step(run_id, step_key)
    end
  end

  # Assistant / Blueprint Synthesis

  @doc """
  Synthesizes a structured workflow blueprint from a natural language prompt.
  Produces standard 5-step DAG chain (research -> code -> verify -> audit -> commit).
  """
  def synthesize_workflow_from_prompt(prompt, project_id, opts \\ []) when is_binary(prompt) do
    slug_base =
      prompt
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/i, "-")
      |> String.slice(0, 40)
      |> String.trim("-")

    slug = if slug_base == "", do: "custom-workflow", else: slug_base

    name =
      Keyword.get(
        opts,
        :name,
        prompt |> String.split("\n") |> hd() |> String.slice(0, 80)
      )

    steps = [
      %{
        "key" => "research",
        "kind" => "deep_research",
        "title" => "Deep Research: #{prompt}",
        "depends_on" => [],
        "params" => %{
          "query" => prompt,
          "level" => "medium",
          "max_sources" => 5
        },
        "model_config" => %{"reasoning_effort" => "high"},
        "safety_policy" => "read_only"
      },
      %{
        "key" => "code_gen",
        "kind" => "swarm_code_gen",
        "title" => "Swarm Implementation: #{prompt}",
        "depends_on" => ["research"],
        "params" => %{
          "prompt" => prompt,
          "context_summary" => "{{steps.research.output.report}}",
          "agent_count" => 2
        },
        "model_config" => %{"reasoning_effort" => "medium"},
        "safety_policy" => "full_auto"
      },
      %{
        "key" => "verify_tests",
        "kind" => "test_verification",
        "title" => "Automated Test Suite Verification",
        "depends_on" => ["code_gen"],
        "params" => %{
          "test_command" => "mix test",
          "fail_fast" => true
        },
        "model_config" => %{"reasoning_effort" => "none"},
        "safety_policy" => "read_only"
      },
      %{
        "key" => "security_audit",
        "kind" => "security_audit",
        "title" => "Security & Safety Audit",
        "depends_on" => ["verify_tests"],
        "params" => %{
          "strict" => false
        },
        "model_config" => %{"reasoning_effort" => "high"},
        "safety_policy" => "read_only"
      },
      %{
        "key" => "git_commit",
        "kind" => "git_commit",
        "title" => "Atomic Git Commit",
        "depends_on" => ["security_audit"],
        "params" => %{
          "commit_message" => "feat: #{prompt}",
          "stage_all" => true
        },
        "model_config" => %{"reasoning_effort" => "none"},
        "safety_policy" => "prompt_dangerous"
      }
    ]

    variables = [
      %{
        "name" => "feature_name",
        "type" => "string",
        "default" => prompt,
        "description" => "Objective or feature being implemented",
        "required" => true
      }
    ]

    %{
      "project_id" => project_id,
      "name" => name,
      "slug" => slug,
      "description" => "Autonomous pipeline for: #{prompt}",
      "tags" => ["autonomous", "swarm", "full-cycle"],
      "variables" => variables,
      "steps" => steps
    }
  end

  # Helpers

  defp resolve_workflow_inputs(variables, inputs) when is_list(variables) and is_map(inputs) do
    Enum.reduce(variables, inputs, fn var, acc ->
      name = Map.get(var, "name") || Map.get(var, :name)
      default = Map.get(var, "default") || Map.get(var, :default)

      if name && not Map.has_key?(acc, name) && not Map.has_key?(acc, to_string(name)) do
        Map.put(acc, to_string(name), default)
      else
        acc
      end
    end)
  end

  defp resolve_workflow_inputs(_vars, inputs), do: inputs

  defp broadcast_workflow(workflow, event) do
    try do
      Phoenix.PubSub.broadcast(@pubsub, "workflows:#{workflow.project_id}", event)
    rescue
      _ -> :ok
    end
  end

  defp broadcast_run(run, event) do
    try do
      Phoenix.PubSub.broadcast(@pubsub, "workflow_run:#{run.id}", event)

      if run.project_id do
        Phoenix.PubSub.broadcast(@pubsub, "workflow_runs:project:#{run.project_id}", event)
      end
    rescue
      _ -> :ok
    end
  end

  defp validate_required_variables(variables, inputs)
       when is_list(variables) and is_map(inputs) do
    missing =
      Enum.reduce(variables, [], fn var, acc ->
        required? = Map.get(var, "required") == true or Map.get(var, :required) == true
        name = Map.get(var, "name") || Map.get(var, :name)

        has_default? =
          (Map.has_key?(var, "default") and not is_nil(Map.get(var, "default"))) or
            (Map.has_key?(var, :default) and not is_nil(Map.get(var, :default)))

        has_input? = has_valid_input?(inputs, name)

        if required? and not has_input? and not has_default? do
          acc ++ [to_string(name)]
        else
          acc
        end
      end)

    case missing do
      [] -> :ok
      _ -> {:error, missing}
    end
  end

  defp validate_required_variables(_vars, _inputs), do: :ok

  defp has_valid_input?(inputs, name) when is_binary(name) do
    (Map.has_key?(inputs, name) and not is_nil(Map.get(inputs, name))) or
      Enum.any?(inputs, fn {k, v} -> to_string(k) == name and not is_nil(v) end)
  end

  defp has_valid_input?(inputs, name) when is_atom(name) do
    has_valid_input?(inputs, Atom.to_string(name))
  end

  defp has_valid_input?(_inputs, _name), do: false
end
