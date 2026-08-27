defmodule IexCode.Engine.SessionServer do
  @moduledoc """
  GenServer process managing the active execution state of a coding session.
  Handles incoming prompts, tool executions, autonomous goal lifecycles,
  real-time steering message ingestion, and swarm dispatching.
  """
  # Every public entry point rehydrates on demand through ensure_started/1.
  # Keeping children temporary avoids restart storms when the database itself is
  # unavailable during init; the next caller becomes the bounded retry owner.
  use GenServer, restart: :temporary
  require Logger
  alias IexCode.{LLM, Projects, Sessions, Tools, WorkspacePath}
  alias IexCode.Engine.{AgentRegistry, AgentSupervisor, OperationManager, SwarmCoordinator}
  alias IexCode.Runs.RunDispatcher
  alias Phoenix.PubSub

  @cancel_session_attempts 5
  @session_call_attempts 5
  @default_idle_timeout_ms 30 * 60 * 1_000

  # Client API

  def start_link(session_id) do
    GenServer.start_link(__MODULE__, session_id, name: via_tuple(session_id))
  end

  def ensure_started(session_id) do
    case GenServer.whereis(via_tuple(session_id)) do
      nil ->
        case start_session_child(session_id) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, reason} -> {:error, reason}
        end

      pid ->
        {:ok, pid}
    end
  end

  defp start_session_child(session_id) do
    DynamicSupervisor.start_child(
      IexCode.Engine.SessionSupervisor,
      {__MODULE__, session_id}
    )
  catch
    :exit, reason -> {:error, {:session_supervisor_unavailable, reason}}
  end

  @doc """
  Creates and starts an autonomous goal for the session.
  """
  def create_goal(session_id, goal_prompt_or_params, opts \\ []) do
    call_session_server(
      session_id,
      {:create_goal, goal_prompt_or_params, opts},
      30_000,
      retry_after_call_exit?: false
    )
  end

  @doc """
  Sends a user prompt to the active session. If session is running, ingests as real-time steering.
  """
  def send_prompt(session_id, content, opts \\ []) do
    call_session_server(session_id, {:send_prompt, content, opts}, 30_000,
      retry_after_call_exit?: false
    )
  end

  @doc """
  Sends real-time steering guidance into an active swarm loop.
  Broadcasts to session:SESSION_ID:steer and session:SESSION_ID.
  """
  def send_steering(session_id, steer_text) do
    call_session_server(session_id, {:send_steering, steer_text}, 5_000,
      retry_after_call_exit?: false
    )
  end

  @doc """
  Alias for send_steering/2.
  """
  def steer_swarm(session_id, steer_text) do
    send_steering(session_id, steer_text)
  end

  @doc """
  Pauses the active swarm or single-agent execution without losing context.
  """
  def pause_session(session_id) do
    call_session_server(session_id, :pause_session, 5_000, retry_after_call_exit?: false)
  end

  @doc """
  Resumes execution of a paused session.
  """
  def resume_session(session_id) do
    call_session_server(session_id, :resume_session, 5_000, retry_after_call_exit?: false)
  end

  @doc """
  Cancels the active session execution, stops all subagent OTP workers,
  and executes :rollback or :commit action.
  """
  def cancel_session(session_id, opts \\ []) do
    call_session_server(session_id, {:cancel_session, opts}, 30_000,
      attempts: @cancel_session_attempts,
      retry_after_call_exit?: :ambiguous
    )
  end

  def toggle_swarm(session_id) do
    call_session_server(session_id, :toggle_swarm, 5_000, retry_after_call_exit?: false)
  end

  def clear_operations(session_id) do
    call_session_server(session_id, :clear_operations)
  end

  def get_state(session_id) do
    call_session_server(session_id, :get_state)
  end

  @doc false
  def update_idle_timeout(timeout_ms) when is_integer(timeout_ms) and timeout_ms > 0 do
    IexCode.Engine.SessionSupervisor
    |> DynamicSupervisor.which_children()
    |> Enum.each(fn
      {_id, pid, _type, _modules} when is_pid(pid) ->
        GenServer.cast(pid, {:update_idle_timeout, timeout_ms})

      _child ->
        :ok
    end)

    :ok
  catch
    :exit, _reason -> :ok
  end

  defp call_session_server(session_id, request, timeout \\ 5_000, opts \\ []) do
    attempts = Keyword.get(opts, :attempts, @session_call_attempts)
    retry_after_call_exit? = Keyword.get(opts, :retry_after_call_exit?, true)

    do_call_session_server(
      session_id,
      request,
      timeout,
      attempts,
      retry_after_call_exit?
    )
  end

  defp do_call_session_server(
         session_id,
         request,
         timeout,
         attempts,
         retry_after_call_exit?
       ) do
    case ensure_started(session_id) do
      {:ok, pid} ->
        send(pid, :session_activity)

        call_exact_session_server(
          session_id,
          pid,
          request,
          timeout,
          attempts,
          retry_after_call_exit?
        )

      {:error, :session_not_found} = error ->
        error

      {:error, _reason} when attempts > 1 ->
        session_supervisor_barrier(attempts)

        do_call_session_server(
          session_id,
          request,
          timeout,
          attempts - 1,
          retry_after_call_exit?
        )

      {:error, reason} ->
        {:error, {:session_unavailable, reason}}
    end
  end

  defp call_exact_session_server(
         session_id,
         pid,
         request,
         timeout,
         attempts,
         retry_after_call_exit?
       ) do
    try do
      # Call the exact process returned by DynamicSupervisor. Looking the name
      # up again creates a TOCTOU window when that child is restarting.
      GenServer.call(pid, request, timeout)
    catch
      :exit, reason ->
        cond do
          retry_after_call_exit? == :ambiguous and session_call_exit?(reason) ->
            {:error, {:session_call_ambiguous, reason}}

          not retryable_session_call_exit?(reason) ->
            exit(reason)

          retry_after_call_exit? == true and attempts > 1 ->
            session_supervisor_barrier(attempts)

            do_call_session_server(
              session_id,
              request,
              timeout,
              attempts - 1,
              retry_after_call_exit?
            )

          true ->
            {:error, {:session_unavailable, reason}}
        end
    end
  end

  defp retryable_session_call_exit?({reason, {GenServer, :call, _call}})
       when reason in [:noproc, :normal, :shutdown, :killed],
       do: true

  defp retryable_session_call_exit?({{:shutdown, _detail}, {GenServer, :call, _call}}), do: true
  defp retryable_session_call_exit?(_reason), do: false

  defp session_call_exit?({_reason, {GenServer, :call, _call}}), do: true
  defp session_call_exit?(_reason), do: false

  # Serializing through the DynamicSupervisor is the ordering barrier between a
  # child's DOWN and a retry. A short bounded timer then yields to database or
  # registry recovery without Process.sleep/1 blocking this caller's mailbox.
  defp session_supervisor_barrier(attempts) do
    try do
      _ = DynamicSupervisor.which_children(IexCode.Engine.SessionSupervisor)
    catch
      :exit, _reason -> :ok
    end

    retry_number = max(@session_call_attempts - attempts + 1, 1)
    ref = make_ref()
    timer = Process.send_after(self(), {ref, :retry_session_server}, min(retry_number * 10, 50))

    receive do
      {^ref, :retry_session_server} -> :ok
    after
      100 -> Process.cancel_timer(timer, async: true, info: false)
    end

    :ok
  end

  @doc false
  def dispatch_run_control(controller_node, operation, args, opts \\ [])

  def dispatch_run_control(controller_node, operation, args, opts)
      when is_atom(controller_node) and operation in [:pause, :resume, :cancel, :steer] and
             is_list(args) and is_list(opts) do
    dispatcher = Keyword.get(opts, :dispatcher, RunDispatcher)
    timeout = Keyword.get(opts, :timeout, 5_000)

    try do
      if controller_node == node() do
        apply(dispatcher, operation, args)
      else
        case Keyword.get(opts, :rpc) do
          rpc when is_function(rpc, 5) ->
            rpc.(controller_node, dispatcher, operation, args, timeout)

          _default ->
            :erpc.call(controller_node, dispatcher, operation, args, timeout)
        end
      end
    rescue
      error -> {:error, {:durable_dispatch_unavailable, Exception.message(error)}}
    catch
      kind, reason -> {:error, {:durable_dispatch_unavailable, kind, reason}}
    end
  end

  def dispatch_run_control(_controller_node, _operation, _args, _opts),
    do: {:error, :invalid_durable_dispatch}

  defp via_tuple(session_id) do
    {:via, Registry, {IexCode.SessionRegistry, session_id}}
  end

  # Server Callbacks

  @impl true
  def init(session_id) do
    case fetch_session_for_start(session_id) do
      {:ok, session} -> init_session(session_id, session)
      {:error, reason} -> {:stop, reason}
    end
  end

  defp init_session(session_id, session) do
    status = normalize_status(session.status)

    {swarm_owner, swarm_metadata, swarm_lookup_error} =
      case AgentRegistry.swarm_owner_registration(session_id) do
        {:ok, pid, metadata} -> {pid, metadata, nil}
        {:error, {:swarm_owner_metadata_unavailable, pid, reason}} -> {pid, %{}, reason}
        :none -> {nil, %{}, nil}
      end

    state = %{
      session_id: session_id,
      session: session,
      status: status,
      current_task: nil,
      task_ref: nil,
      run_mode: nil,
      active_goal: nil,
      idle_timeout_ms:
        Application.get_env(:iex_code, :session_idle_timeout_ms, @default_idle_timeout_ms),
      idle_timer: nil,
      idle_timer_handle: nil
    }

    state =
      cond do
        is_pid(swarm_owner) and swarm_lookup_error ->
          track_unavailable_owner(state, swarm_owner, swarm_lookup_error)

        is_pid(swarm_owner) ->
          track_registered_owner(state, swarm_owner, swarm_metadata)

        true ->
          state
      end

    # Adopt the uniquely registered coordinator after a SessionServer restart.
    # Without a live owner, a DB row left in "running" is phantom-running and
    # must be normalized rather than allowing a second coordinator to start.
    state =
      cond do
        is_pid(swarm_owner) ->
          adopted_status = state.status

          if status != adopted_status do
            update_db_session_status(session_id, to_string(adopted_status))
            broadcast(session_id, {:session_status_changed, to_string(adopted_status)})
          end

          %{
            state
            | status: adopted_status,
              session: %{session | status: to_string(adopted_status)}
          }

        status == :running ->
          Logger.warning(
            "Session #{session_id} restarted while marked running; marking interrupted"
          )

          update_db_session_status(session_id, "idle")
          broadcast(session_id, {:session_status_changed, "idle"})
          broadcast(session_id, {:session_interrupted, %{session_id: session_id}})

          %{state | status: :idle, session: %{session | status: "idle"}}

        true ->
          state
      end

    goal_session_status =
      if status == :running and not is_pid(swarm_owner), do: :interrupted, else: state.status

    state = %{state | active_goal: restore_active_goal(session_id, goal_session_status)}
    {:ok, schedule_idle_passivation(state)}
  end

  # A stale UI/process must not recreate an in-memory SessionServer after its
  # durable session has been deleted. Database failures stay distinguishable
  # from a genuinely missing row so callers can retry transient startup races.
  defp fetch_session_for_start(session_id) do
    case Sessions.get_session(session_id) do
      %Sessions.Session{} = session -> {:ok, session}
      nil -> {:error, :session_not_found}
    end
  rescue
    error -> {:error, {:session_lookup_failed, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:session_lookup_failed, kind, reason}}
  end

  @impl true
  def handle_call(
        {:create_goal, _goal_prompt_or_params, _opts},
        _from,
        %{status: status} = state
      )
      when status in [:running, :paused],
      do: {:reply, {:error, :already_running}, state}

  @impl true
  def handle_call(
        {:create_goal, goal_prompt_or_params, opts},
        from,
        %{session_id: session_id} = state
      ) do
    case AgentRegistry.swarm_owner_registration(session_id) do
      {:ok, owner, metadata} ->
        {:reply, {:error, :already_running}, track_registered_owner(state, owner, metadata)}

      {:error, {:swarm_owner_metadata_unavailable, owner, reason}} ->
        {:reply, {:error, :already_running}, track_unavailable_owner(state, owner, reason)}

      :none ->
        handle_create_goal(goal_prompt_or_params, opts, from, state)
    end
  end

  @impl true
  def handle_call({:send_steering, steer_text}, _from, %{session_id: session_id} = state) do
    cleaned = normalize_steering(steer_text)
    state = refresh_registered_owner(state)

    result =
      if cleaned == "" do
        {:ok, cleaned}
      else
        route_steering(state, cleaned)
      end

    if cleaned != "" and match?({:ok, _}, result) and not durable_steering_route?(state) do
      # Interactive steering has no durable run-control receipt, so the session
      # server owns its message and UI notification. Durable steering is instead
      # persisted and acknowledged exactly once by the coordinator after it has
      # ingested the claimed control.
      case Sessions.create_message(%{
             session_id: session_id,
             role: "user",
             agent_name: "User (Steer)",
             content: "🧭 **Steering Guidance**: #{cleaned}"
           }) do
        {:ok, msg} -> broadcast(session_id, {:message_created, msg})
        _ -> :ok
      end

      broadcast(session_id, {:swarm_steered, %{session_id: session_id, steering: cleaned}})
    end

    {:reply, result, state}
  end

  @impl true
  def handle_call(:pause_session, _from, state) do
    state = refresh_registered_owner(state)

    case state.run_mode do
      {:durable_swarm, run_id} -> pause_durable_run(run_id, state)
      {:swarm_owner_metadata_unavailable, _reason} -> owner_metadata_unavailable_reply(state)
      {:stale_durable_swarm, _run_id} -> stale_owner_reply(state)
      _interactive_or_idle -> pause_interactive_run(state)
    end
  end

  @impl true
  def handle_call(:resume_session, _from, state) do
    state = refresh_registered_owner(state)

    case state.run_mode do
      {:durable_swarm, run_id} -> resume_durable_run(run_id, state)
      {:swarm_owner_metadata_unavailable, _reason} -> owner_metadata_unavailable_reply(state)
      {:stale_durable_swarm, _run_id} -> stale_owner_reply(state)
      _interactive_or_idle -> resume_interactive_run(state)
    end
  end

  @impl true
  def handle_call({:send_prompt, raw_prompt, opts}, _from, state) do
    {:noreply, new_state} = handle_send_prompt(raw_prompt, opts, state)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(
        {:cancel_session, opts},
        _from,
        state
      ) do
    state = refresh_registered_owner(state)

    if state.status == :stopped and is_nil(state.run_mode) do
      {:reply, {:ok, %{status: :stopped, action: :already_stopped}}, state}
    else
      case state.run_mode do
        {:durable_swarm, run_id} -> cancel_durable_run(run_id, opts, state)
        {:swarm_owner_metadata_unavailable, _reason} -> owner_metadata_unavailable_reply(state)
        {:stale_durable_swarm, _run_id} -> stale_owner_reply(state)
        _interactive_or_idle -> cancel_interactive_run(opts, state)
      end
    end
  end

  @impl true
  def handle_call(:toggle_swarm, _from, %{session: session, session_id: session_id} = state) do
    current_session = fetch_current_session(session_id, session)

    new_mode = !current_session.swarm_mode

    case Sessions.update_session(current_session, %{swarm_mode: new_mode}) do
      {:ok, updated_session} ->
        broadcast(session_id, {:session_updated, updated_session})
        {:reply, {:ok, new_mode}, %{state | session: updated_session}}

      _ ->
        updated = %{current_session | swarm_mode: new_mode}
        broadcast(session_id, {:session_updated, updated})
        {:reply, {:ok, new_mode}, %{state | session: updated}}
    end
  end

  @impl true
  def handle_call(:clear_operations, _from, %{session_id: session_id} = state) do
    try do
      Sessions.clear_session_operations(session_id)
    rescue
      _ -> :ok
    end

    broadcast(session_id, :operations_cleared)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    state = refresh_registered_owner(state)

    if state.status in [:running, :paused, :stopped] do
      # While a run is actively managed by this process, the cached state is
      # authoritative - skip the blocking DB read.
      {:reply, state, state}
    else
      current_session = fetch_current_session(state.session_id, state.session)

      result_state = %{
        state
        | session: current_session,
          status: normalize_status(current_session.status)
      }

      {:reply, result_state, result_state}
    end
  end

  @impl true
  def handle_cast({:update_idle_timeout, timeout_ms}, state) do
    {:noreply, state |> Map.put(:idle_timeout_ms, timeout_ms) |> schedule_idle_passivation()}
  end

  def handle_cast({:send_prompt, raw_prompt}, state),
    do: handle_send_prompt(raw_prompt, [], state)

  def handle_cast(
        {:send_prompt, raw_prompt, opts},
        state
      ),
      do: handle_send_prompt(raw_prompt, opts, state)

  defp handle_send_prompt(
         raw_prompt,
         opts,
         %{session_id: session_id, session: session} = state
       ) do
    prompt = String.trim(raw_prompt)

    {registered_owner, owner_metadata} =
      case AgentRegistry.swarm_owner_registration(session_id) do
        {:ok, pid, metadata} ->
          {pid, metadata}

        {:error, {:swarm_owner_metadata_unavailable, pid, reason}} ->
          {pid, {:metadata_unavailable, reason}}

        :none ->
          {nil, %{}}
      end

    if state.status in [:running, :paused] or is_pid(registered_owner) do
      # A paused coordinator is still the active owner. Prompts must be
      # delivered to that exact task rather than starting a split-brain swarm.
      state =
        case owner_metadata do
          {:metadata_unavailable, reason} ->
            track_unavailable_owner(state, registered_owner, reason)

          metadata ->
            track_registered_owner(state, registered_owner, metadata)
        end

      {:reply, _, new_state} = handle_call({:send_steering, prompt}, nil, state)
      {:noreply, new_state}
    else
      is_swarm_cmd = String.starts_with?(prompt, "/swarm")

      cleaned_prompt =
        if is_swarm_cmd do
          prompt |> String.replace_prefix("/swarm", "") |> String.trim()
        else
          prompt
        end

      actual_prompt =
        if cleaned_prompt == "", do: "Analyze workspace and coordinate task", else: cleaned_prompt

      # Save User message
      {user_msg, _} =
        case Sessions.create_message(%{
               session_id: session_id,
               role: "user",
               agent_name: "User",
               content: prompt
             }) do
          {:ok, msg} ->
            {msg, nil}

          error ->
            Logger.error(
              "Failed to persist user message for session #{session_id}: #{inspect(error)}"
            )

            broadcast(
              session_id,
              {:run_failed, %{session_id: session_id, reason: inspect(error)}}
            )

            {%{
               id: Ecto.UUID.generate(),
               session_id: session_id,
               role: "user",
               agent_name: "User",
               content: prompt
             }, error}
        end

      broadcast(session_id, {:message_created, user_msg})

      current_session = fetch_current_session(session_id, session)

      update_db_session_status(session_id, "running")
      broadcast(session_id, {:session_status_changed, "running"})

      use_swarm? = is_swarm_cmd or current_session.swarm_mode
      project_root = resolve_project_root(current_session)

      if use_swarm? do
        # Run Swarm Coordinator
        case SwarmCoordinator.run_swarm(session_id, actual_prompt, project_root,
               allowed_tools: Keyword.get(opts, :allowed_tools, :all)
             ) do
          {:ok, task_pid} ->
            task_ref = Process.monitor(task_pid)

            {:noreply,
             %{
               state
               | status: :running,
                 current_task: task_pid,
                 task_ref: task_ref,
                 run_mode: :swarm,
                 session: %{current_session | status: "running"}
             }}

          {:error, reason} ->
            Logger.error(
              "Failed to start swarm task for session #{session_id}: #{inspect(reason)}"
            )

            update_db_session_status(session_id, "idle")
            broadcast(session_id, {:session_status_changed, "idle"})

            broadcast(
              session_id,
              {:run_failed, %{session_id: session_id, reason: inspect(reason)}}
            )

            {:noreply,
             %{
               state
               | status: :idle,
                 current_task: nil,
                 task_ref: nil,
                 run_mode: nil,
                 session: %{current_session | status: "idle"}
             }}
        end
      else
        # Run Single Agent Async Task
        parent = self()

        case Task.Supervisor.start_child(IexCode.TaskSupervisor, fn ->
               allow_sandbox(parent, self())

               run_single_agent(
                 session_id,
                 current_session,
                 actual_prompt,
                 project_root,
                 Keyword.get(opts, :allowed_tools, :all)
               )
             end) do
          {:ok, task_pid} ->
            task_ref = Process.monitor(task_pid)

            {:noreply,
             %{
               state
               | status: :running,
                 current_task: task_pid,
                 task_ref: task_ref,
                 run_mode: :single_agent,
                 session: %{current_session | status: "running"}
             }}

          {:error, reason} ->
            Logger.error(
              "Failed to start single-agent task for session #{session_id}: #{inspect(reason)}"
            )

            update_db_session_status(session_id, "idle")
            broadcast(session_id, {:session_status_changed, "idle"})

            broadcast(
              session_id,
              {:run_failed, %{session_id: session_id, reason: inspect(reason)}}
            )

            {:noreply, %{state | status: :idle}}
        end
      end
    end
  end

  @impl true
  def handle_info({:session_idle_timeout, timer_ref}, %{idle_timer: timer_ref} = state) do
    state =
      state
      |> Map.put(:idle_timer, nil)
      |> Map.put(:idle_timer_handle, nil)
      |> refresh_registered_owner()

    if idle_passivation_safe?(state) do
      {:stop, :normal, state}
    else
      {:noreply, schedule_idle_passivation(state), :hibernate}
    end
  end

  def handle_info({:session_idle_timeout, _stale_ref}, state), do: {:noreply, state}

  def handle_info(:session_activity, state), do: {:noreply, schedule_idle_passivation(state)}

  @impl true
  def handle_info(
        {:DOWN, ref, :process, pid, :noconnection},
        %{task_ref: ref, current_task: pid} = state
      )
      when node(pid) != node() do
    # A node partition is not proof that the remote coordinator died. Keep the
    # session fail-closed until global ownership/metadata can be observed again;
    # marking it idle here could admit a conflicting interactive coordinator.
    {:noreply,
     %{
       state
       | current_task: nil,
         task_ref: nil,
         run_mode: {:swarm_owner_metadata_unavailable, :owner_node_disconnected}
     }}
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, %{task_ref: task_ref} = state)
      when ref == task_ref do
    case AgentRegistry.swarm_owner_registration(state.session_id) do
      {:ok, replacement, metadata} when replacement != pid ->
        # A retry can acquire the session immediately after this generation
        # exits. Adopt it instead of letting the stale DOWN normalize the
        # shared session to idle and lose durable control routing.
        {:noreply,
         state
         |> Map.put(:current_task, nil)
         |> Map.put(:task_ref, nil)
         |> track_registered_owner(replacement, metadata)}

      {:error, {:swarm_owner_metadata_unavailable, replacement, reason}}
      when replacement != pid ->
        {:noreply,
         state
         |> Map.put(:current_task, nil)
         |> Map.put(:task_ref, nil)
         |> track_unavailable_owner(replacement, reason)}

      _none_or_same_owner ->
        finish_task_down(state, reason)
    end
  end

  @impl true
  def handle_info({ref, _result}, state) when is_reference(ref) do
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp schedule_idle_passivation(state) do
    if state.idle_timer_handle do
      Process.cancel_timer(state.idle_timer_handle, async: true, info: false)
    end

    timer_ref = make_ref()

    timer_handle =
      Process.send_after(self(), {:session_idle_timeout, timer_ref}, state.idle_timeout_ms)

    %{state | idle_timer: timer_ref, idle_timer_handle: timer_handle}
  end

  defp idle_passivation_safe?(state) do
    inactive? =
      state.status in [:idle, :stopped, :completed, :failed] and is_nil(state.current_task) and
        is_nil(state.task_ref) and is_nil(state.run_mode)

    resumable_paused_owner? =
      state.status == :paused and is_pid(task_pid(state.current_task)) and
        (state.run_mode == :swarm or match?({:durable_swarm, _run_id}, state.run_mode))

    inactive? or resumable_paused_owner?
  end

  defp restore_active_goal(session_id, session_status) do
    case Sessions.latest_goal_checkpoint(session_id) do
      %{id: id, content: content, metadata: metadata, inserted_at: inserted_at}
      when is_map(metadata) ->
        stored_status = Map.get(metadata, "goal_status")
        {fallback_title, fallback_prompt} = parse_goal_message(content)

        if stored_status in ~w(idle running paused stopped completed failed) do
          %{
            id: Map.get(metadata, "goal_id", id),
            session_id: session_id,
            title: Map.get(metadata, "goal_title", fallback_title),
            prompt: fallback_prompt,
            status: restored_goal_status(session_status, stored_status),
            created_at: inserted_at
          }
        end

      _not_a_draft_checkpoint ->
        nil
    end
  rescue
    _error -> nil
  catch
    _kind, _reason -> nil
  end

  defp parse_goal_message(content) when is_binary(content) do
    content = String.replace_prefix(content, "🎯 **Goal**: ", "")

    case String.split(content, "\n\n", parts: 2) do
      [title, prompt] -> {String.slice(title, 0, 240), prompt}
      [prompt] -> {String.slice(prompt, 0, 240), prompt}
    end
  end

  defp parse_goal_message(_content), do: {"Autonomous Goal", "Analyze workspace"}

  defp restored_goal_status(:running, _stored), do: :running
  defp restored_goal_status(:paused, _stored), do: :paused
  defp restored_goal_status(:failed, _stored), do: :failed
  defp restored_goal_status(:interrupted, _stored), do: :failed
  defp restored_goal_status(:stopped, _stored), do: :stopped
  defp restored_goal_status(:completed, _stored), do: :completed
  # Interactive swarm completion returns the durable session to `idle`, while
  # its creation checkpoint remains `running`. With no registered owner, that
  # pair represents a normally completed goal rather than a lost draft.
  defp restored_goal_status(:idle, "running"), do: :completed
  defp restored_goal_status(:idle, "completed"), do: :completed
  defp restored_goal_status(:idle, "failed"), do: :failed
  defp restored_goal_status(:idle, "stopped"), do: :stopped
  defp restored_goal_status(_session_status, "failed"), do: :failed
  defp restored_goal_status(_session_status, _stored), do: :idle

  defp run_single_agent(session_id, session, user_prompt, project_root, allowed_tools) do
    subscribe_steering(session_id)
    broadcast(session_id, {:session_status_changed, "running"})

    # Zero-arg fun polled by the LLM stream between chunks (contract: `:cancelled?`)
    cancelled? = fn -> steering_cancelled?() end

    try do
      case control_checkpoint() do
        :cancel ->
          finish_cancelled(session_id)

        :go ->
          # Fetch previous messages
          prev_messages =
            try do
              Sessions.list_messages(session_id, limit: 20, content_limit: 20_000)
              |> Enum.map(fn m -> %{role: m.role, content: m.content} end)
            rescue
              _ -> []
            end

          system_prompt = """
          You are an intelligent, proactive coding assistant in the IexCode web environment.
          You have tools to read, search, modify, and run code in the user's project workspace (#{project_root}).
          When using tools, you can execute them directly.
          """

          # Spawn root LLM operation
          op_result =
            OperationManager.run_sync_operation(
              session_id,
              nil,
              "AssistantAgent",
              "llm_stream",
              "Agent: Planning response & tool execution",
              %{prompt: user_prompt},
              fn progress ->
                progress.(
                  20,
                  "Querying model (#{session.model_provider}: #{session.model_name})..."
                )

                LLM.chat(prev_messages, system_prompt, session, fn _c -> :ok end,
                  cancelled?: cancelled?,
                  allowed_tools: allowed_tools
                )
              end
            )

          # The stream may have been aborted by a cancel that the `cancelled?`
          # fun observed - honor it before processing the result.
          case control_checkpoint() do
            :cancel -> throw({:session_cancelled, session_id})
            :go -> :ok
          end

          case op_result do
            {:ok, %{text: response_text, tool_calls: tool_calls}} ->
              # If there are tool calls, execute each in a dedicated process!
              tool_results =
                Enum.map(tool_calls, fn tc ->
                  trusted_args =
                    if is_map(tc.args) do
                      Map.merge(tc.args, %{
                        "project_id" => session.project_id,
                        "run_id" => nil,
                        "session_id" => session_id
                      })
                    else
                      %{
                        "project_id" => session.project_id,
                        "run_id" => nil,
                        "session_id" => session_id
                      }
                    end

                  case control_checkpoint() do
                    :cancel ->
                      throw({:session_cancelled, session_id})

                    :go ->
                      tool_result =
                        if tool_allowed?(tc.name, allowed_tools) do
                          OperationManager.run_sync_operation(
                            session_id,
                            nil,
                            "AssistantAgent",
                            tc.name,
                            "Tool: #{tc.name} (#{Map.get(trusted_args, "path", Map.get(trusted_args, "command", ""))})",
                            trusted_args,
                            fn progress ->
                              Tools.execute(tc.name, trusted_args, project_root, progress)
                            end
                          )
                        else
                          {:error, {:tool_not_allowed, tc.name}}
                        end

                      case tool_result do
                        {:ok, out} -> %{name: tc.name, result: out}
                        {:error, err} -> %{name: tc.name, error: err}
                      end
                  end
                end)

              final_content =
                if tool_results != [] and response_text == "" do
                  summarized =
                    Enum.map(tool_results, fn tr ->
                      "**Tool `#{tr.name}` completed:**\n```\n#{String.slice(to_string(tr[:result] || tr[:error]), 0, 1000)}\n```"
                    end)
                    |> Enum.join("\n\n")

                  "Executed #{length(tool_results)} operations:\n\n" <> summarized
                else
                  response_text
                end

              case Sessions.create_message(%{
                     session_id: session_id,
                     role: "assistant",
                     agent_name: "Assistant",
                     content: final_content
                   }) do
                {:ok, asst_msg} -> broadcast(session_id, {:message_created, asst_msg})
                _ -> :ok
              end

            {:error, reason} ->
              case Sessions.create_message(%{
                     session_id: session_id,
                     role: "assistant",
                     agent_name: "Assistant",
                     content: "⚠️ Error during execution: #{inspect(reason)}"
                   }) do
                {:ok, err_msg} -> broadcast(session_id, {:message_created, err_msg})
                _ -> :ok
              end
          end

          update_db_session_status(session_id, "idle")
          broadcast(session_id, {:session_status_changed, "idle"})
      end
    rescue
      error ->
        Logger.error(
          "Single-agent run failed for session #{session_id}: #{Exception.format(:error, error)}"
        )

        update_db_session_status(session_id, "failed")
        broadcast(session_id, {:session_status_changed, "failed"})

        broadcast(
          session_id,
          {:run_failed, %{session_id: session_id, reason: Exception.message(error)}}
        )

        case Sessions.create_message(%{
               session_id: session_id,
               role: "assistant",
               agent_name: "Assistant",
               content: "❌ **Run Failed**: #{Exception.message(error)}"
             }) do
          {:ok, err_msg} -> broadcast(session_id, {:message_created, err_msg})
          _ -> :ok
        end
    catch
      :throw, {:session_cancelled, ^session_id} ->
        finish_cancelled(session_id)
    after
      unsubscribe_steering(session_id)
    end
  end

  defp tool_allowed?(_tool_name, :all), do: true
  defp tool_allowed?(_tool_name, nil), do: true

  defp tool_allowed?(tool_name, allowed_tools) when is_list(allowed_tools),
    do: to_string(tool_name) in Enum.map(allowed_tools, &to_string/1)

  defp tool_allowed?(_tool_name, _allowed_tools), do: false

  # Blocks while paused and drains control messages. Returns :go or :cancel.
  defp control_checkpoint do
    receive do
      {:pause, _session_id} ->
        wait_while_paused()

      {:resume, _session_id} ->
        control_checkpoint()

      {:cancel, _session_id, _opts} ->
        :cancel

      _msg ->
        control_checkpoint()
    after
      0 -> :go
    end
  end

  defp wait_while_paused do
    receive do
      {:resume, _session_id} ->
        control_checkpoint()

      {:cancel, _session_id, _opts} ->
        :cancel

      _msg ->
        wait_while_paused()
    end
  end

  # Non-blocking cancel check for the LLM stream; re-queues any other message
  # so pause/resume/steer deliveries are not lost.
  defp steering_cancelled? do
    receive do
      {:cancel, _session_id, _opts} ->
        true

      msg ->
        send(self(), msg)
        false
    after
      0 -> false
    end
  end

  defp finish_cancelled(session_id) do
    update_db_session_status(session_id, "stopped")
    broadcast(session_id, {:session_status_changed, "stopped"})
  end

  defp subscribe_steering(session_id) do
    PubSub.subscribe(IexCode.PubSub, "session:#{session_id}:steer")
  rescue
    _ -> :ok
  end

  defp unsubscribe_steering(session_id) do
    PubSub.unsubscribe(IexCode.PubSub, "session:#{session_id}:steer")
  rescue
    _ -> :ok
  end

  defp fetch_current_session(session_id, fallback) do
    try do
      Sessions.get_session(session_id) || fallback
    rescue
      _ -> fallback
    catch
      _, _ -> fallback
    end
  end

  defp handle_create_goal(
         goal_prompt_or_params,
         opts,
         _from,
         %{session_id: session_id, session: session} = state
       ) do
    {title, prompt} = normalize_goal(goal_prompt_or_params)

    current_session = fetch_current_session(session_id, session)

    project_root = resolve_project_root(current_session, opts)
    auto_start = Keyword.get(opts, :auto_start, true)

    goal_record = %{
      id: Ecto.UUID.generate(),
      session_id: session_id,
      title: title,
      prompt: prompt,
      status: if(auto_start, do: :running, else: :idle),
      created_at: DateTime.utc_now()
    }

    if auto_start do
      # Acquire the shared session-swarm ownership before making the goal
      # observable. A durable worker can win ownership after the earlier
      # preflight lookup; persisting first would leave a ghost goal/message on
      # this losing side of that race.
      run_opts = Keyword.put(opts, :ownership_token, goal_record.id)

      case SwarmCoordinator.run_swarm(session_id, prompt, project_root, run_opts) do
        {:ok, task_pid} ->
          persist_goal_message(session_id, goal_record)
          broadcast(session_id, {:goal_created, goal_record})

          update_db_session_status(session_id, "running")
          broadcast(session_id, {:session_status_changed, "running"})

          task_ref = Process.monitor(task_pid)

          new_state = %{
            state
            | session: %{current_session | status: "running"},
              status: :running,
              current_task: task_pid,
              task_ref: task_ref,
              run_mode: :swarm,
              active_goal: goal_record
          }

          {:reply, {:ok, Map.put(goal_record, :task_pid, task_pid)}, new_state}

        {:error, reason} ->
          case AgentRegistry.swarm_owner_registration(session_id) do
            {:ok, owner, metadata} ->
              {:reply, {:error, {:swarm_start_failed, reason}},
               track_registered_owner(state, owner, metadata)}

            {:error, {:swarm_owner_metadata_unavailable, owner, lookup_reason}} ->
              {:reply, {:error, {:swarm_start_failed, reason}},
               track_unavailable_owner(state, owner, lookup_reason)}

            :none ->
              failed_goal = %{goal_record | status: :failed}
              update_db_session_status(session_id, "idle")
              broadcast(session_id, {:session_status_changed, "idle"})

              broadcast(
                session_id,
                {:run_failed, %{session_id: session_id, reason: inspect(reason)}}
              )

              {:reply, {:error, {:swarm_start_failed, reason}},
               %{
                 state
                 | status: :idle,
                   session: %{current_session | status: "idle"},
                   active_goal: failed_goal
               }}
          end
      end
    else
      persist_goal_message(session_id, goal_record)
      broadcast(session_id, {:goal_created, goal_record})

      update_db_session_status(session_id, "idle")
      broadcast(session_id, {:session_status_changed, "idle"})

      new_state = %{
        state
        | session: %{current_session | status: "idle"},
          status: :idle,
          current_task: nil,
          active_goal: goal_record
      }

      {:reply, {:ok, goal_record}, new_state}
    end
  end

  defp persist_goal_message(session_id, goal_record) do
    title = goal_record.title
    prompt = goal_record.prompt

    user_msg =
      case Sessions.create_message(%{
             session_id: session_id,
             role: "user",
             agent_name: "User (Goal)",
             content: "🎯 **Goal**: #{title}\n\n#{prompt}",
             metadata: %{
               "goal_id" => goal_record.id,
               "goal_title" => title,
               "goal_status" => to_string(goal_record.status)
             }
           }) do
        {:ok, msg} ->
          msg

        error ->
          Logger.error(
            "Failed to persist goal message for session #{session_id}: #{inspect(error)}"
          )

          broadcast(session_id, {:run_failed, %{session_id: session_id, reason: inspect(error)}})

          %{
            id: Ecto.UUID.generate(),
            session_id: session_id,
            role: "user",
            agent_name: "User (Goal)",
            content: "🎯 **Goal**: #{title}\n\n#{prompt}"
          }
      end

    broadcast(session_id, {:message_created, user_msg})
  end

  defp normalize_goal(value) when is_binary(value) do
    prompt = value |> String.trim() |> String.slice(0, 100_000)
    prompt = if prompt == "", do: "Analyze workspace and coordinate goal", else: prompt
    {String.slice(prompt, 0, 60), prompt}
  end

  defp normalize_goal(value) when is_map(value) do
    title = map_string(value, [:title]) |> String.trim() |> String.slice(0, 240)

    description =
      map_string(value, [:prompt, :description])
      |> String.trim()
      |> String.slice(0, 100_000)

    title = if title == "", do: "Autonomous Goal", else: title
    {title, if(description == "", do: title, else: description)}
  end

  defp normalize_goal(_value),
    do: {"Autonomous Goal", "Analyze workspace and coordinate goal"}

  defp map_string(map, keys) do
    Enum.find_value(keys, "", fn key ->
      case Map.get(map, key) || Map.get(map, Atom.to_string(key)) do
        value when is_binary(value) -> if(String.trim(value) == "", do: nil, else: value)
        _ -> nil
      end
    end)
  end

  defp normalize_steering(value) when is_binary(value),
    do: value |> String.trim() |> String.slice(0, 8_000)

  defp normalize_steering(_value), do: ""

  defp cancel_interactive_run(
         opts,
         %{session_id: session_id, session: session} = state
       ) do
    # Honor legacy `commit: true` while letting an explicit `:action` win.
    default_action = if Keyword.get(opts, :commit, false), do: :commit, else: :rollback
    action = Keyword.get(opts, :action, default_action)

    current_session = fetch_current_session(session_id, session)

    project_root = resolve_project_root(current_session, opts)
    mutation_project_id = trusted_project_id_for_root(current_session, project_root)

    # 1. Signal all workers via PubSub. A live swarm coordinator subscribes to
    #    this topic and performs its own rollback/commit + termination, so the
    #    server must NOT roll back again for that path (avoid double-delivery).
    PubSub.broadcast(IexCode.PubSub, "session:#{session_id}:steer", {:cancel, session_id, opts})

    # 2. Wait briefly for the running task to die on its own (it also observes
    #    the {:cancel, ...} message), then escalate shutdown -> kill.
    swarm_handled_cancel? =
      case task_pid(state.current_task) do
        nil ->
          false

        pid ->
          if process_alive?(pid) do
            await_task_exit(pid)

            # The swarm coordinator cleans up on its own; the single-agent task
            # does not, so the server performs the rollback/commit for it.
            state.run_mode == :swarm
          else
            false
          end
      end

    if state.task_ref, do: Process.demonitor(state.task_ref, [:flush])

    # 3. Cleanly terminate all subagent OTP workers
    AgentSupervisor.stop_all_agents(session_id)

    # 4. Perform rollback or commit (only if the swarm coordinator didn't already)
    unless swarm_handled_cancel? do
      case action do
        :rollback ->
          IexCode.Tools.MultiPatch.Snapshot.claim_unscoped(project_root, session_id)

          SwarmCoordinator.perform_rollback(
            project_root,
            %SwarmCoordinator.State{
              session_id: session_id,
              session: %{project_id: mutation_project_id},
              project_root: project_root
            }
          )

        :commit ->
          commit_opts =
            opts
            |> Keyword.drop([:project_id, :run_id, :session_id])
            |> maybe_put_project_id(mutation_project_id)
            |> Keyword.put(:session_id, session_id)

          SwarmCoordinator.perform_commit(
            project_root,
            commit_opts
          )

        _ ->
          :ok
      end
    end

    # 5. Update DB status
    update_db_session_status(session_id, "stopped")

    # 6. Create the cancellation message only when this server owned cleanup.
    # A live swarm coordinator persists its own terminal message before exit.
    unless swarm_handled_cancel? do
      try do
        case Sessions.create_message(%{
               session_id: session_id,
               role: "assistant",
               agent_name: "Swarm Coordinator",
               content:
                 "🛑 **Session Stopped**: Execution cancelled by user with action `#{action}`."
             }) do
          {:ok, cancel_msg} -> broadcast(session_id, {:message_created, cancel_msg})
          _ -> :ok
        end
      rescue
        error ->
          Logger.warning(
            "Could not persist cancellation message for session #{session_id}: #{Exception.message(error)}"
          )
      catch
        kind, reason ->
          Logger.warning(
            "Could not persist cancellation message for session #{session_id}: #{inspect({kind, reason})}"
          )
      end
    end

    broadcast(session_id, {:session_status_changed, "stopped"})
    broadcast(session_id, {:session_cancelled, %{session_id: session_id, action: action}})

    await_cancel_reply_barrier(opts)

    new_state = %{
      state
      | status: :stopped,
        current_task: nil,
        task_ref: nil,
        run_mode: nil,
        session: %{current_session | status: "stopped"}
    }

    {:reply, {:ok, %{status: :stopped, action: action}}, new_state}
  end

  # Explicit post-effect safe-point for deterministic crash-boundary testing and
  # controlled embedding. The caller monitors this exact GenServer, so killing
  # it after the notification proves that cancel effects can precede a lost
  # reply without the client automatically repeating those effects.
  defp await_cancel_reply_barrier(opts) do
    case Keyword.get(opts, :cancel_reply_barrier) do
      {controller, reference} when is_pid(controller) and is_reference(reference) ->
        monitor = Process.monitor(controller)
        send(controller, {:cancel_reply_barrier, self(), reference})

        receive do
          {:release_cancel_reply_barrier, ^reference} ->
            Process.demonitor(monitor, [:flush])
            :ok

          {:DOWN, ^monitor, :process, ^controller, _reason} ->
            exit(:cancel_reply_barrier_owner_down)
        end

      _none ->
        :ok
    end
  end

  defp finish_task_down(state, reason) do
    status =
      if state.status == :stopped do
        :stopped
      else
        case reason do
          :normal -> :idle
          :noproc -> :idle
          :shutdown -> :stopped
          :killed -> :stopped
          _ -> :failed
        end
      end

    session_id = state.session_id
    update_db_session_status(session_id, to_string(status))
    broadcast(session_id, {:session_status_changed, to_string(status)})

    if status == :failed do
      Logger.error("Session #{session_id} run crashed: #{inspect(reason)}")
      broadcast(session_id, {:run_failed, %{session_id: session_id, reason: inspect(reason)}})

      case Sessions.create_message(%{
             session_id: session_id,
             role: "assistant",
             agent_name: "Swarm Coordinator",
             content: "❌ **Run Failed**: The session run crashed with `#{inspect(reason)}`."
           }) do
        {:ok, err_msg} -> broadcast(session_id, {:message_created, err_msg})
        _ -> :ok
      end
    end

    {:noreply, %{state | status: status, current_task: nil, task_ref: nil, run_mode: nil}}
  end

  defp pause_durable_run(
         run_id,
         %{session_id: session_id, session: session} = state
       ) do
    case dispatch_durable_control(state, :pause, [run_id]) do
      {:ok, _run} ->
        current_session = fetch_current_session(session_id, session)
        update_db_session_status(session_id, "paused")
        broadcast(session_id, {:session_status_changed, "paused"})

        {:reply, {:ok, :paused},
         %{state | status: :paused, session: %{current_session | status: "paused"}}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp pause_interactive_run(%{session_id: session_id, session: session} = state) do
    current_session = fetch_current_session(session_id, session)

    update_db_session_status(session_id, "paused")
    PubSub.broadcast(IexCode.PubSub, "session:#{session_id}:steer", {:pause, session_id})
    broadcast(session_id, {:session_status_changed, "paused"})

    {:reply, {:ok, :paused},
     %{state | status: :paused, session: %{current_session | status: "paused"}}}
  end

  defp resume_durable_run(
         run_id,
         %{session_id: session_id, session: session} = state
       ) do
    case dispatch_durable_control(state, :resume, [run_id]) do
      {:ok, _run} ->
        current_session = fetch_current_session(session_id, session)
        update_db_session_status(session_id, "running")
        broadcast(session_id, {:session_status_changed, "running"})

        {:reply, {:ok, :running},
         %{state | status: :running, session: %{current_session | status: "running"}}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp resume_interactive_run(%{session_id: session_id, session: session} = state) do
    task_alive? =
      case task_pid(state.current_task) do
        nil -> false
        pid -> process_alive?(pid)
      end

    if state.status == :paused and task_alive? do
      current_session = fetch_current_session(session_id, session)

      update_db_session_status(session_id, "running")
      PubSub.broadcast(IexCode.PubSub, "session:#{session_id}:steer", {:resume, session_id})
      broadcast(session_id, {:session_status_changed, "running"})

      {:reply, {:ok, :running},
       %{state | status: :running, session: %{current_session | status: "running"}}}
    else
      # No live task to resume - never phantom-resume into :running.
      new_state =
        if task_alive? do
          state
        else
          update_db_session_status(session_id, "idle")
          broadcast(session_id, {:session_status_changed, "idle"})
          %{state | status: :idle, current_task: nil, task_ref: nil}
        end

      {:reply, {:error, :no_active_run}, new_state}
    end
  end

  defp cancel_durable_run(
         run_id,
         opts,
         %{session_id: session_id, session: session} = state
       ) do
    action =
      Keyword.get(
        opts,
        :action,
        if(Keyword.get(opts, :commit, false), do: :commit, else: :rollback)
      )

    if action == :rollback do
      case dispatch_durable_control(state, :cancel, [run_id]) do
        {:ok, _run} ->
          current_session = fetch_current_session(session_id, session)
          update_db_session_status(session_id, "stopped")
          broadcast(session_id, {:session_status_changed, "stopped"})

          {:reply, {:ok, %{status: :stopped, action: :rollback}},
           %{state | status: :stopped, session: %{current_session | status: "stopped"}}}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    else
      # The durable dispatcher currently persists cancellation as rollback.
      # Reject commit/no-op requests rather than reporting success for the
      # opposite destructive action.
      {:reply, {:error, :durable_cancel_action_unsupported}, state}
    end
  end

  defp refresh_registered_owner(%{session_id: session_id} = state) do
    case AgentRegistry.swarm_owner_registration(session_id) do
      {:ok, owner, metadata} ->
        track_registered_owner(state, owner, metadata)

      {:error, {:swarm_owner_metadata_unavailable, owner, reason}} ->
        track_unavailable_owner(state, owner, reason)

      :none ->
        state
    end
  end

  defp route_steering(%{run_mode: {:durable_swarm, run_id}} = state, cleaned) do
    dispatch_durable_control(state, :steer, [run_id, cleaned])
    |> case do
      {:ok, _run} -> {:ok, cleaned}
      {:error, _reason} = error -> error
    end
  end

  defp route_steering(%{run_mode: {:swarm_owner_metadata_unavailable, _reason}}, _cleaned),
    do: {:error, :swarm_owner_metadata_unavailable}

  defp route_steering(%{run_mode: {:stale_durable_swarm, _run_id}}, _cleaned),
    do: {:error, :stale_swarm_owner}

  defp route_steering(%{session_id: session_id}, cleaned) do
    PubSub.broadcast(
      IexCode.PubSub,
      "session:#{session_id}:steer",
      {:steer_message, cleaned}
    )

    {:ok, cleaned}
  end

  defp durable_steering_route?(%{run_mode: {:durable_swarm, run_id}})
       when is_binary(run_id),
       do: true

  defp durable_steering_route?(_state), do: false

  defp dispatch_durable_control(state, operation, args) do
    case task_pid(state.current_task) do
      owner when is_pid(owner) -> dispatch_run_control(node(owner), operation, args)
      _missing -> {:error, :durable_dispatch_unavailable}
    end
  end

  defp owner_metadata_unavailable_reply(state),
    do: {:reply, {:error, :swarm_owner_metadata_unavailable}, state}

  defp stale_owner_reply(state), do: {:reply, {:error, :stale_swarm_owner}, state}

  defp track_registered_owner(state, owner, metadata) when is_pid(owner) do
    {run_mode, status} = registered_owner_projection(state, metadata)

    if state.current_task == owner do
      %{state | status: status, run_mode: run_mode}
    else
      if state.task_ref, do: Process.demonitor(state.task_ref, [:flush])

      %{
        state
        | status: status,
          current_task: owner,
          task_ref: Process.monitor(owner),
          run_mode: run_mode
      }
    end
  end

  defp track_registered_owner(state, _owner, _metadata), do: state

  defp track_unavailable_owner(state, owner, reason) when is_pid(owner) do
    same_owner? = state.current_task == owner
    run_mode = {:swarm_owner_metadata_unavailable, reason}

    if same_owner? do
      %{state | run_mode: run_mode}
    else
      if state.task_ref, do: Process.demonitor(state.task_ref, [:flush])

      %{
        state
        | status: if(state.status == :paused, do: :paused, else: :running),
          current_task: owner,
          task_ref: Process.monitor(owner),
          run_mode: run_mode
      }
    end
  end

  defp track_unavailable_owner(state, _owner, _reason), do: state

  defp registered_owner_projection(
         state,
         %{
           run_id: run_id,
           run_attempt: attempt,
           lease_generation: generation,
           lease_owner: lease_owner
         }
       )
       when is_binary(run_id) and is_integer(attempt) and is_integer(generation) and
              is_binary(lease_owner) do
    case IexCode.Runs.get_run(run_id) do
      %{attempt: ^attempt, lease_generation: ^generation, status: status}
      when status in ["cancelled", "interrupted"] ->
        {{:stale_durable_swarm, run_id}, :stopped}

      %{attempt: ^attempt, lease_generation: ^generation, status: "failed"} ->
        {{:stale_durable_swarm, run_id}, :failed}

      %{attempt: ^attempt, lease_generation: ^generation, status: "completed"} ->
        {{:stale_durable_swarm, run_id}, :idle}

      %{
        attempt: ^attempt,
        lease_generation: ^generation,
        lease_owner: ^lease_owner,
        lease_expires_at: %DateTime{} = lease_expires_at,
        status: status
      } ->
        live_lease? = DateTime.compare(lease_expires_at, DateTime.utc_now()) == :gt

        cond do
          live_lease? and status == "paused" ->
            {{:durable_swarm, run_id}, :paused}

          live_lease? and status == "running" ->
            {{:durable_swarm, run_id}, :running}

          true ->
            {{:stale_durable_swarm, run_id}, state.status}
        end

      _stale_or_missing ->
        {{:stale_durable_swarm, run_id}, state.status}
    end
  rescue
    error ->
      {{:swarm_owner_metadata_unavailable, {:run_lookup_failed, Exception.message(error)}},
       state.status}
  end

  defp registered_owner_projection(state, _metadata),
    do: {:swarm, if(state.status == :paused, do: :paused, else: :running)}

  # Accepts a raw pid or a %Task{} struct (Task.Supervisor.async_nolink returns
  # a %Task{}; start_child returns a pid).
  defp task_pid(pid) when is_pid(pid), do: pid
  defp task_pid(%Task{pid: pid}) when is_pid(pid), do: pid
  defp task_pid(_), do: nil

  defp process_alive?(pid) when is_pid(pid) and node(pid) == node(), do: Process.alive?(pid)

  defp process_alive?(pid) when is_pid(pid) do
    :erpc.call(node(pid), Process, :alive?, [pid], 1_000)
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  # Waits for a task to exit on its own (it may be handling a cancel message),
  # then escalates shutdown -> kill. Always returns once the process is down.
  defp await_task_exit(pid, grace_ms \\ 3_000) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} ->
        :ok
    after
      grace_ms ->
        Process.exit(pid, :shutdown)

        receive do
          {:DOWN, ^ref, :process, ^pid, _reason} ->
            :ok
        after
          1_000 ->
            Process.exit(pid, :kill)

            receive do
              {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
            after
              500 -> Process.demonitor(ref, [:flush])
            end
        end
    end
  end

  defp resolve_project_root(session, opts \\ []) do
    opts[:project_root] ||
      (((session && Ecto.assoc_loaded?(session.project)) and session.project) &&
         session.project.root_path) ||
      File.cwd!()
  end

  defp trusted_project_id_for_root(%{project_id: project_id}, project_root)
       when is_binary(project_id) and is_binary(project_root) do
    project = Projects.get_project!(project_id)

    with {:ok, registered_root} <- WorkspacePath.resolve(project.root_path, ""),
         {:ok, requested_root} <- WorkspacePath.resolve(project_root, ""),
         true <- registered_root == requested_root do
      project_id
    else
      _ -> if(sandbox_test_environment?(), do: nil, else: project_id)
    end
  rescue
    _ -> if(sandbox_test_environment?(), do: nil, else: project_id)
  catch
    _, _ -> if(sandbox_test_environment?(), do: nil, else: project_id)
  end

  defp trusted_project_id_for_root(_session, _project_root), do: nil

  defp maybe_put_project_id(opts, project_id) when is_binary(project_id),
    do: Keyword.put(opts, :project_id, project_id)

  defp maybe_put_project_id(opts, _project_id), do: opts

  defp sandbox_test_environment? do
    Application.get_env(:iex_code, IexCode.Repo, [])[:pool] == Ecto.Adapters.SQL.Sandbox
  end

  defp update_db_session_status(session_id, status_str) do
    case Sessions.get_session(session_id) do
      nil -> :ok
      s -> Sessions.update_session(s, %{status: status_str})
    end
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp allow_sandbox(parent, child) do
    if Code.ensure_loaded?(Ecto.Adapters.SQL.Sandbox) do
      try do
        Ecto.Adapters.SQL.Sandbox.allow(IexCode.Repo, parent, child)
      rescue
        _ -> :ok
      catch
        _, _ -> :ok
      end
    end
  end

  defp normalize_status("running"), do: :running
  defp normalize_status("paused"), do: :paused
  defp normalize_status("stopped"), do: :stopped
  defp normalize_status("completed"), do: :completed
  defp normalize_status("failed"), do: :failed
  defp normalize_status(:running), do: :running
  defp normalize_status(:paused), do: :paused
  defp normalize_status(:stopped), do: :stopped
  defp normalize_status(:completed), do: :completed
  defp normalize_status(:failed), do: :failed
  defp normalize_status(_), do: :idle

  defp broadcast(session_id, event) do
    PubSub.broadcast(IexCode.PubSub, "session:#{session_id}", event)
  rescue
    _ -> :ok
  end
end
