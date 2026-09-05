defmodule IexCodeWeb.WorkflowsLive do
  @moduledoc """
  Standalone LiveView for Grok-Like Workflows (Requirement R1, R2).
  Supports Gallery (:index), Visual Builder / Prompt Assistant (:new),
  Workflow Details (:show), and Real-Time SVG Execution Cockpit (:run).
  """

  use IexCodeWeb, :live_view
  import IexCodeWeb.WorkflowComponents

  alias IexCode.{Projects, Sessions, Workflows}
  alias IexCode.Workflows.{Workflow, WorkflowRun}

  # ============================================================================
  # MOUNT
  # ============================================================================

  @impl true
  def mount(params, _session, socket) do
    context_session = load_context_session(params["id"] || params["session_id"])
    project = resolve_project(context_session)

    if connected?(socket) and project do
      Phoenix.PubSub.subscribe(IexCode.PubSub, "workflows:#{project.id}")
      Phoenix.PubSub.subscribe(IexCode.PubSub, "workflow_runs:project:#{project.id}")
    end

    workflows = if project, do: Workflows.list_workflows(project.id), else: []
    active_runs = if project, do: Workflows.list_runs(project.id, limit: 15), else: []

    {:ok,
     socket
     |> assign(:project, project)
     |> assign(:context_session, context_session)
     |> assign(:return_path, return_path(context_session))
     |> assign(:workflows, workflows)
     |> assign(:active_runs, active_runs)
     |> assign(:search_query, "")
     |> assign(:tag_filter, "all")
     |> assign(:show_launch_modal, false)
     |> assign(:launching_workflow, nil)
     |> assign(:launch_form, nil)
     |> assign(:show_create_modal, false)
     |> assign(:workflow, nil)
     |> assign(:run, nil)
     |> assign(:active_run_id, nil)
     |> assign(:selected_step_key, nil)
     |> assign(:selected_step, nil)
     |> assign(:inspector_tab, :logs)
     |> assign(:zoom_level, 1.0)
     |> assign(:pan_offset, %{x: 0.0, y: 0.0})
     |> assign(:blueprint_prompt, "")
     |> assign(:synthesis_loading?, false)
     |> assign(:workflow_form, default_workflow_form(project))}
  end

  # ============================================================================
  # HANDLE PARAMS (ROUTE DISPATCH)
  # ============================================================================

  @impl true
  def handle_params(params, _uri, socket) do
    # Unsubscribe from prior run if changing routes
    maybe_unsubscribe_run(socket)

    case socket.assigns.live_action do
      action when action in [:index, :session_index] ->
        workflows =
          if socket.assigns.project do
            Workflows.list_workflows(socket.assigns.project.id)
          else
            []
          end

        {:noreply,
         socket
         |> assign(:page_title, "Workflows Library")
         |> assign(:workflows, workflows)
         |> assign(:workflow, nil)
         |> assign(:run, nil)
         |> assign(:active_run_id, nil)}

      action when action in [:new, :session_new] ->
        prompt =
          cond do
            is_binary(params["prompt"]) and params["prompt"] != "" ->
              params["prompt"]

            is_binary(params["research_query"]) and params["research_query"] != "" ->
              "Synthesize architectural code implementation based on deep research findings for: #{params["research_query"]}"

            true ->
              socket.assigns.blueprint_prompt || ""
          end

        socket =
          if prompt != "" and socket.assigns.project do
            blueprint =
              Workflows.synthesize_workflow_from_prompt(prompt, socket.assigns.project.id)

            changeset = Workflow.changeset(%Workflow{}, blueprint)

            socket
            |> assign(:blueprint_prompt, prompt)
            |> assign(:workflow_form, to_form(changeset, as: :workflow))
          else
            socket
          end

        {:noreply,
         socket
         |> assign(:page_title, "Create Workflow")
         |> assign(:workflow, nil)
         |> assign(:run, nil)
         |> assign(:active_run_id, nil)}

      action when action in [:show, :session_show] ->
        workflow_id = params["workflow_id"] || params["id"]

        case Workflows.get_workflow(workflow_id) do
          nil ->
            {:noreply,
             socket
             |> put_flash(:error, "Workflow not found")
             |> push_navigate(to: workflows_index_path(socket.assigns.context_session))}

          workflow ->
            runs = Workflows.list_runs(workflow.id, limit: 10)

            {:noreply,
             socket
             |> assign(:page_title, "Workflow: #{workflow.name}")
             |> assign(:workflow, workflow)
             |> assign(:runs, runs)
             |> assign(:run, nil)
             |> assign(:active_run_id, nil)}
        end

      action when action in [:run, :session_run] ->
        run_id = params["run_id"]

        # Subscribe to run topic before reading state (prevents race window)
        if connected?(socket) do
          Phoenix.PubSub.subscribe(IexCode.PubSub, "workflow_run:#{run_id}")
        end

        case Workflows.get_run(run_id) do
          nil ->
            {:noreply,
             socket
             |> put_flash(:error, "Workflow run not found")
             |> push_navigate(to: workflows_index_path(socket.assigns.context_session))}

          run ->
            workflow = run.workflow || Workflows.get_workflow!(run.workflow_id)
            first_step = get_initial_step(run, workflow)

            {:noreply,
             socket
             |> assign(:page_title, "Cockpit · #{workflow.name}")
             |> assign(:active_run_id, run.id)
             |> assign(:workflow, workflow)
             |> assign(:run, run)
             |> assign(:selected_step_key, first_step && step_key(first_step))
             |> assign(:selected_step, first_step)}
        end
    end
  end

  # ============================================================================
  # REAL-TIME PUBSUB HANDLERS
  # ============================================================================

  @impl true
  def handle_info({:workflow_run_updated, %WorkflowRun{} = updated_run}, socket) do
    if socket.assigns.active_run_id == updated_run.id do
      # Refresh run and selected step
      selected_step = find_step(updated_run, socket.assigns.selected_step_key)

      {:noreply,
       socket
       |> assign(:run, updated_run)
       |> assign(:selected_step, selected_step)}
    else
      # Update in active runs list
      active_runs = update_in_runs_list(socket.assigns.active_runs, updated_run)
      {:noreply, assign(socket, :active_runs, active_runs)}
    end
  end

  @impl true
  def handle_info({:step_state_updated, run_id, step_key, new_state}, socket) do
    step_key = to_string(step_key)

    if socket.assigns.active_run_id == run_id and socket.assigns.run do
      run = socket.assigns.run
      current_step_states = run.step_states || %{}

      updated_state =
        Map.update(current_step_states, step_key, %{"status" => new_state}, fn s ->
          Map.put(s, "status", new_state)
        end)

      updated_run = %{run | step_states: updated_state}
      selected_step = find_step(updated_run, socket.assigns.selected_step_key)

      {:noreply,
       socket
       |> assign(:run, updated_run)
       |> assign(:selected_step, selected_step)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:step_state_updated, run_id, step_key, new_state, _metrics}, socket),
    do: handle_info({:step_state_updated, run_id, to_string(step_key), new_state}, socket)

  @impl true
  def handle_info({:workflow_step_started, step_key, _step}, socket) do
    step_key = to_string(step_key)

    if socket.assigns.run do
      selected_step = find_step(socket.assigns.run, step_key)

      {:noreply,
       socket
       |> assign(:selected_step_key, step_key)
       |> assign(:selected_step, selected_step)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:workflow_step_completed, step_key, output}, socket) do
    step_key = to_string(step_key)

    if socket.assigns.run do
      run = socket.assigns.run
      current_step_states = run.step_states || %{}

      updated_state =
        Map.update(
          current_step_states,
          step_key,
          %{"status" => "completed", "output" => output},
          fn s ->
            s |> Map.put("status", "completed") |> Map.put("output", output)
          end
        )

      updated_run = %{run | step_states: updated_state}
      selected_step = find_step(updated_run, socket.assigns.selected_step_key)

      {:noreply,
       socket
       |> assign(:run, updated_run)
       |> assign(:selected_step, selected_step)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:workflow_step_failed, step_key, error}, socket) do
    step_key = to_string(step_key)

    if socket.assigns.run do
      run = socket.assigns.run
      current_step_states = run.step_states || %{}

      updated_state =
        Map.update(
          current_step_states,
          step_key,
          %{"status" => "failed", "error" => error},
          fn s ->
            s |> Map.put("status", "failed") |> Map.put("error", error)
          end
        )

      updated_run = %{run | step_states: updated_state, status: "failed"}
      selected_step = find_step(updated_run, step_key)

      {:noreply,
       socket
       |> assign(:run, updated_run)
       |> assign(:selected_step_key, step_key)
       |> assign(:selected_step, selected_step)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:workflow_run_started, %WorkflowRun{} = run}, socket),
    do: handle_info({:workflow_run_updated, run}, socket)

  @impl true
  def handle_info({:workflow_run_paused, %WorkflowRun{} = run}, socket),
    do: handle_info({:workflow_run_updated, run}, socket)

  @impl true
  def handle_info({:workflow_run_resumed, %WorkflowRun{} = run}, socket),
    do: handle_info({:workflow_run_updated, run}, socket)

  @impl true
  def handle_info({:workflow_run_completed, %WorkflowRun{} = run}, socket),
    do: handle_info({:workflow_run_updated, run}, socket)

  @impl true
  def handle_info({:workflow_run_failed, %WorkflowRun{} = run, _reason}, socket),
    do: handle_info({:workflow_run_updated, run}, socket)

  @impl true
  def handle_info({:workflow_run_launched, %WorkflowRun{} = run}, socket) do
    active_runs = [run | Enum.reject(socket.assigns.active_runs, &(&1.id == run.id))]
    {:noreply, assign(socket, :active_runs, active_runs)}
  end

  @impl true
  def handle_info({:workflow_created, %Workflow{} = workflow}, socket) do
    workflows = [workflow | Enum.reject(socket.assigns.workflows, &(&1.id == workflow.id))]
    {:noreply, assign(socket, :workflows, workflows)}
  end

  @impl true
  def handle_info({:workflow_updated, %Workflow{} = workflow}, socket) do
    workflows =
      Enum.map(socket.assigns.workflows, fn w -> if w.id == workflow.id, do: workflow, else: w end)

    {:noreply, assign(socket, :workflows, workflows)}
  end

  @impl true
  def handle_info({:workflow_deleted, id}, socket) do
    workflows = Enum.reject(socket.assigns.workflows, &(&1.id == id))
    {:noreply, assign(socket, :workflows, workflows)}
  end

  @impl true
  def handle_info(_other, socket), do: {:noreply, socket}

  # ============================================================================
  # USER EVENT HANDLERS
  # ============================================================================

  # Canvas & Selection
  @impl true
  def handle_event("inspect_step", %{"key" => step_key}, socket) do
    selected = find_step(socket.assigns.run || socket.assigns.workflow, step_key)

    {:noreply,
     socket
     |> assign(:selected_step_key, step_key)
     |> assign(:selected_step, selected)}
  end

  @impl true
  def handle_event("close_step_inspector", _params, socket) do
    {:noreply,
     socket
     |> assign(:selected_step_key, nil)
     |> assign(:selected_step, nil)}
  end

  @impl true
  def handle_event("set_inspector_tab", %{"tab" => tab}, socket) do
    atom_tab =
      case tab do
        "logs" -> :logs
        "thinking" -> :thinking
        "metrics" -> :metrics
        "artifacts" -> :artifacts
        _ -> :logs
      end

    {:noreply, assign(socket, :inspector_tab, atom_tab)}
  end

  @impl true
  def handle_event("canvas_pan", %{"x" => x, "y" => y}, socket) do
    {:noreply, assign(socket, :pan_offset, %{x: x * 1.0, y: y * 1.0})}
  end

  @impl true
  def handle_event("canvas_zoom", %{"direction" => "in"}, socket) do
    next = Float.round(min(socket.assigns.zoom_level + 0.15, 2.5), 2)
    {:noreply, assign(socket, :zoom_level, next)}
  end

  @impl true
  def handle_event("canvas_zoom", %{"direction" => "out"}, socket) do
    next = Float.round(max(socket.assigns.zoom_level - 0.15, 0.25), 2)
    {:noreply, assign(socket, :zoom_level, next)}
  end

  @impl true
  def handle_event("canvas_zoom", %{"level" => level}, socket) do
    {:noreply, assign(socket, :zoom_level, level * 1.0)}
  end

  # Search & Filter
  @impl true
  def handle_event("search", %{"query" => query}, socket) do
    {:noreply, assign(socket, :search_query, query)}
  end

  @impl true
  def handle_event("filter_tag", %{"tag" => tag}, socket) do
    {:noreply, assign(socket, :tag_filter, tag)}
  end

  # Launching & Modals
  @impl true
  def handle_event("open_launch_modal", %{"id" => id}, socket) do
    workflow = Workflows.get_workflow!(id)
    vars = workflow.variables || []

    initial_inputs =
      Map.new(vars, fn var ->
        name = Map.get(var, "name") || Map.get(var, :name)
        default = Map.get(var, "default") || Map.get(var, :default) || ""
        {name, default}
      end)

    {:noreply,
     socket
     |> assign(:show_launch_modal, true)
     |> assign(:launching_workflow, workflow)
     |> assign(:launch_form, to_form(initial_inputs, as: :inputs))}
  end

  @impl true
  def handle_event("close_launch_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_launch_modal, false)
     |> assign(:launching_workflow, nil)
     |> assign(:launch_form, nil)}
  end

  @impl true
  def handle_event("launch_workflow", %{"id" => id}, socket) do
    workflow = Workflows.get_workflow!(id)
    vars = workflow.variables || []

    # If has required variables without default, open modal
    required_missing =
      Enum.any?(vars, fn var ->
        (Map.get(var, "required") == true or Map.get(var, :required) == true) and
          is_nil(Map.get(var, "default") || Map.get(var, :default))
      end)

    if required_missing do
      handle_event("open_launch_modal", %{"id" => id}, socket)
    else
      # Default inputs
      inputs =
        Map.new(vars, fn var ->
          name = Map.get(var, "name") || Map.get(var, :name)
          default = Map.get(var, "default") || Map.get(var, :default) || ""
          {name, default}
        end)

      live_async = Application.get_env(:iex_code, :workflows_live_async, true)

      opts = [
        session_id: socket.assigns.context_session && socket.assigns.context_session.id,
        async: live_async
      ]

      case Workflows.launch_workflow(workflow, inputs, opts) do
        {:ok, run} ->
          path = workflow_run_path(socket.assigns.context_session, workflow.id, run.id)

          {:noreply,
           socket
           |> put_flash(:info, "Workflow launched successfully")
           |> push_navigate(to: path)}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Failed to launch: #{inspect(reason)}")}
      end
    end
  end

  @impl true
  def handle_event("submit_launch", %{"inputs" => inputs}, socket) do
    workflow = socket.assigns.launching_workflow
    live_async = Application.get_env(:iex_code, :workflows_live_async, true)

    opts = [
      session_id: socket.assigns.context_session && socket.assigns.context_session.id,
      async: live_async
    ]

    case Workflows.launch_workflow(workflow, inputs, opts) do
      {:ok, run} ->
        path = workflow_run_path(socket.assigns.context_session, workflow.id, run.id)

        {:noreply,
         socket
         |> assign(:show_launch_modal, false)
         |> assign(:launching_workflow, nil)
         |> put_flash(:info, "Workflow launched successfully")
         |> push_navigate(to: path)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Launch failed: #{inspect(reason)}")}
    end
  end

  # Execution Controls
  @impl true
  def handle_event("pause_run", %{"id" => run_id}, socket) do
    case Workflows.pause_run(run_id) do
      :ok ->
        {:noreply, put_flash(socket, :info, "Workflow execution paused")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Cannot pause: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("resume_run", %{"id" => run_id}, socket) do
    case Workflows.resume_run(run_id) do
      :ok ->
        {:noreply, put_flash(socket, :info, "Workflow execution resumed")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Cannot resume: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("cancel_run", %{"id" => run_id}, socket) do
    case Workflows.cancel_run(run_id) do
      :ok ->
        {:noreply, put_flash(socket, :info, "Workflow run cancelled")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Cannot cancel: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("retry_workflow_step", %{"step" => step_key}, socket) do
    step_key = to_string(step_key)
    run = socket.assigns.run
    run_id = socket.assigns.active_run_id || (run && run.id)

    if run && Map.get(run.step_states || %{}, step_key, %{})["status"] in ["failed", "cancelled"] do
      db_run = Workflows.get_run(run_id)

      if db_run &&
           Map.get(db_run.step_states || %{}, step_key, %{})["status"] not in [
             "failed",
             "cancelled"
           ] do
        new_states = Map.put(db_run.step_states || %{}, step_key, %{"status" => "failed"})
        Workflows.update_run(db_run, %{step_states: new_states})
      end
    end

    case Workflows.retry_step(run_id, step_key) do
      {:ok, updated_run} ->
        {:noreply,
         socket
         |> assign(:run, updated_run)
         |> put_flash(:info, "Retrying step #{step_key}...")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to retry step: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("retry_workflow_step", %{"step_key" => step_key}, socket),
    do: handle_event("retry_workflow_step", %{"step" => step_key}, socket)

  # Workflow Builder & Synthesis
  @impl true
  def handle_event("synthesize_blueprint", %{"prompt" => prompt}, socket) do
    prompt = String.trim(prompt)

    if prompt == "" do
      {:noreply, put_flash(socket, :error, "Please enter an objective prompt")}
    else
      blueprint = Workflows.synthesize_workflow_from_prompt(prompt, socket.assigns.project.id)
      changeset = Workflow.changeset(%Workflow{}, blueprint)

      {:noreply,
       socket
       |> assign(:blueprint_prompt, prompt)
       |> assign(:workflow_form, to_form(changeset, as: :workflow))
       |> put_flash(:info, "Workflow blueprint synthesized successfully")}
    end
  end

  @impl true
  def handle_event("validate_workflow", %{"workflow" => params}, socket) do
    changeset =
      %Workflow{}
      |> Workflow.changeset(workflow_form_params(params, socket))
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :workflow_form, to_form(changeset, as: :workflow))}
  end

  @impl true
  def handle_event("save_workflow", %{"workflow" => params}, socket) do
    params = workflow_form_params(params, socket)

    case Workflows.create_workflow(params) do
      {:ok, workflow} ->
        path = workflow_path(socket.assigns.context_session, workflow.id)

        {:noreply,
         socket
         |> put_flash(:info, "Workflow saved successfully")
         |> push_navigate(to: path)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(:workflow_form, to_form(changeset, as: :workflow))
         |> put_flash(:error, "Please correct the highlighted errors")}
    end
  end

  @impl true
  def handle_event("delete_workflow", %{"id" => id}, socket) do
    workflow = Workflows.get_workflow!(id)

    case Workflows.delete_workflow(workflow) do
      {:ok, _deleted} ->
        workflows = Enum.reject(socket.assigns.workflows, &(&1.id == id))

        {:noreply,
         socket
         |> assign(:workflows, workflows)
         |> put_flash(:info, "Workflow deleted successfully")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to delete workflow")}
    end
  end

  @impl true
  def handle_event("chain_to_swarm", params, socket) do
    query = params["query"] || "Research Findings"
    prompt = "Implement production code based on deep research findings for: #{query}"

    base_path = workflows_new_path(socket.assigns.context_session)
    path = "#{base_path}?prompt=#{URI.encode(prompt)}"

    {:noreply, push_navigate(socket, to: path)}
  end

  # ============================================================================
  # HELPERS & ACCESSORS
  # ============================================================================

  defp default_workflow_form(project) do
    project_id = if project, do: project.id, else: nil

    blueprint =
      Workflows.synthesize_workflow_from_prompt("Automated Full-Cycle Implementation", project_id)

    %Workflow{}
    |> Workflow.changeset(blueprint)
    |> to_form(as: :workflow)
  end

  defp workflow_form_params(params, socket) do
    existing_steps =
      case socket.assigns[:workflow_form] do
        %{source: %Ecto.Changeset{} = changeset} ->
          Ecto.Changeset.get_field(changeset, :steps) || []

        _ ->
          []
      end

    params
    |> Map.put("project_id", socket.assigns.project.id)
    |> Map.put_new("steps", existing_steps)
  end

  defp load_context_session(nil), do: nil

  defp load_context_session(id) do
    Sessions.get_session(id)
  rescue
    _ -> nil
  end

  defp resolve_project(nil) do
    case Projects.list_projects() do
      [first | _] ->
        first

      [] ->
        cwd = File.cwd!()
        {:ok, p} = Projects.get_or_create_project(cwd, Path.basename(cwd))
        p
    end
  end

  defp resolve_project(%{project_id: project_id}) when is_binary(project_id) do
    Projects.get_project!(project_id)
  rescue
    _ -> resolve_project(nil)
  end

  defp resolve_project(_), do: resolve_project(nil)

  defp return_path(nil), do: ~p"/"
  defp return_path(session), do: ~p"/sessions/#{session.id}"

  def workflows_index_path(nil), do: ~p"/workflows"
  def workflows_index_path(session), do: ~p"/sessions/#{session.id}/workflows"

  def workflows_new_path(nil), do: ~p"/workflows/new"
  def workflows_new_path(session), do: ~p"/sessions/#{session.id}/workflows/new"

  def workflow_path(nil, id), do: ~p"/workflows/#{id}"
  def workflow_path(session, id), do: ~p"/sessions/#{session.id}/workflows/#{id}"

  def workflow_run_path(nil, workflow_id, run_id),
    do: ~p"/workflows/#{workflow_id}/runs/#{run_id}"

  def workflow_run_path(session, workflow_id, run_id),
    do: ~p"/sessions/#{session.id}/workflows/#{workflow_id}/runs/#{run_id}"

  defp maybe_unsubscribe_run(socket) do
    if old_run_id = socket.assigns[:active_run_id] do
      Phoenix.PubSub.unsubscribe(IexCode.PubSub, "workflow_run:#{old_run_id}")
    end
  end

  defp get_initial_step(run, workflow) do
    steps = run.resolved_steps || (workflow && workflow.steps) || []

    if run.current_step_key do
      Enum.find(steps, &(step_key(&1) == run.current_step_key)) || List.first(steps)
    else
      List.first(steps)
    end
  end

  defp find_step(nil, _key), do: nil

  defp find_step(%WorkflowRun{} = run, key) do
    steps = run.resolved_steps || (run.workflow && run.workflow.steps) || []
    Enum.find(steps, &(step_key(&1) == to_string(key)))
  end

  defp find_step(%Workflow{} = workflow, key) do
    steps = workflow.steps || []
    Enum.find(steps, &(step_key(&1) == to_string(key)))
  end

  defp find_step(steps, key) when is_list(steps) do
    Enum.find(steps, &(step_key(&1) == to_string(key)))
  end

  defp find_step(_, _), do: nil

  defp update_in_runs_list(runs, updated_run) do
    Enum.map(runs, fn r -> if r.id == updated_run.id, do: updated_run, else: r end)
  end
end
