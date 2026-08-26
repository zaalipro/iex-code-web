defmodule IexCode.Engine.SwarmCoordinator do
  @moduledoc """
  Coordinates multi-agent autonomous swarm workflows using isolated OTP GenServers
  (PlannerAgent, ExplorerAgent, CoderAgent, VerifierAgent) managed by AgentSupervisor.
  Implements real-time steering message ingestion, pause/resume/cancel lifecycle control,
  and an autonomous self-healing error feedback loop with a configurable,
  bounded retry ceiling (0–10) and cycle detection.
  """
  require Logger

  alias IexCode.Engine.{
    AgentRegistry,
    AgentSupervisor,
    FleetManager,
    FleetRuntime,
    FleetSupervisor
  }

  alias IexCode.Engine.Agents.{PlannerAgent, ExplorerAgent, CoderAgent, VerifierAgent}
  alias IexCode.Execution.Limits
  alias IexCode.Tools
  alias IexCode.Tools.{AutoFix, MultiPatch}
  alias IexCode.{Runs, Sessions}
  alias Phoenix.PubSub

  @max_steering_directives 64
  @max_steering_bytes 8_000
  @max_steering_context_bytes 128_000
  @swarm_start_timeout 5_000

  defmodule State do
    defstruct [
      :session_id,
      :run_id,
      :session,
      :project_root,
      :user_prompt,
      :root_op_id,
      :allowed_tools,
      :workspace_lock_delegation,
      :run_lease_owner,
      :run_attempt,
      :run_lease_generation,
      :run_lease_ms,
      :execution_policy,
      :control_barrier,
      fleet_agents: [],
      stage: :init,
      iteration: 0,
      max_retries: 3,
      start_time_ms: 0,
      stage_start_ms: 0,
      plan: nil,
      explorer_context: nil,
      coder_result: nil,
      verifier_result: nil,
      applied_patches: [],
      applied_snapshots: [],
      steer_directives: [],
      error_signatures: MapSet.new(),
      history: [],
      status: :running
    ]
  end

  @doc """
  Runs the full swarm lifecycle asynchronously for a session and prompt under TaskSupervisor.
  Supports `run_swarm(session_id, prompt)`, `run_swarm(session_id, prompt, project_root)`,
  and `run_swarm(session_id, prompt, project_root, opts)`.
  Returns `{:ok, task_pid}`.
  """
  def run_swarm(session_id, user_prompt, project_root_or_opts \\ [], opts \\ []) do
    {project_root, options} =
      cond do
        is_binary(project_root_or_opts) ->
          {project_root_or_opts, opts}

        is_list(project_root_or_opts) ->
          {Keyword.get(project_root_or_opts, :project_root), project_root_or_opts}

        true ->
          {nil, opts}
      end

    run_opts =
      if project_root do
        Keyword.put(options, :project_root, project_root)
      else
        options
      end

    lock = {{__MODULE__, :session_swarm, session_id}, self()}
    requested_identity = swarm_owner_identity(run_opts)

    with :ok <- validate_durable_swarm_owner_identity(run_opts) do
      case :global.trans(lock, fn ->
             case AgentRegistry.swarm_owner_registration(session_id) do
               {:ok, pid, metadata} ->
                 if Map.take(metadata, Map.keys(requested_identity)) == requested_identity do
                   {:ok, pid}
                 else
                   {:error, {:session_swarm_owned, metadata[:run_id] || :interactive}}
                 end

               {:error, {:swarm_owner_metadata_unavailable, _pid, _reason}} ->
                 {:error, :swarm_owner_metadata_unavailable}

               :none ->
                 start_swarm_task(session_id, user_prompt, project_root, run_opts, true)
             end
           end) do
        :aborted -> {:error, :swarm_ownership_lock_failed}
        {:aborted, reason} -> {:error, {:swarm_ownership_lock_failed, reason}}
        result -> result
      end
    end
  end

  @doc """
  Sends real-time steering text directly to the coordinator via PubSub.
  """
  def send_steering(session_id, steer_text) do
    PubSub.broadcast(IexCode.PubSub, "session:#{session_id}:steer", {:steer_message, steer_text})
  end

  @doc """
  Pauses the swarm coordinator.

  Persists "paused" before broadcasting: if the coordinator task has not
  subscribed yet, the broadcast is lost, so the persisted status is the
  reliable signal (the coordinator re-checks it right after subscribing).
  """
  def pause(session_id) do
    update_db_session_status(session_id, "paused")
    PubSub.broadcast(IexCode.PubSub, "session:#{session_id}:steer", {:pause, session_id})
  end

  @doc """
  Resumes the paused swarm coordinator.
  """
  def resume(session_id) do
    PubSub.broadcast(IexCode.PubSub, "session:#{session_id}:steer", {:resume, session_id})
  end

  @doc """
  Cancels the active swarm coordinator.
  """
  def cancel(session_id, opts \\ []) do
    PubSub.broadcast(IexCode.PubSub, "session:#{session_id}:steer", {:cancel, session_id, opts})
  end

  @doc """
  Reverts working tree modifications recorded in this session's MultiPatch snapshots.
  When no session is scoped (default `%State{}`), falls back to all snapshots.
  Never touches unrelated files or git state.
  """
  def perform_rollback(_project_root, state \\ %State{}) do
    session_id = Map.get(state, :session_id)
    run_id = Map.get(state, :run_id)

    if is_binary(session_id) and session_id != "" do
      snapshots =
        if is_binary(run_id) and run_id != "" do
          MultiPatch.Snapshot.list_run_snapshots(run_id)
        else
          MultiPatch.Snapshot.list_snapshots(session_id)
        end

      lock_opts = [
        project_id: trusted_project_id(state),
        run_id: run_id,
        session_id: session_id
      ]

      results =
        Enum.map(snapshots, fn snapshot ->
          Tools.rollback_multi_patch(snapshot.transaction_id, snapshot.project_root, lock_opts)
        end)

      case Enum.filter(results, &match?({:error, _}, &1)) do
        [] -> {:ok, :rolled_back}
        errors -> {:error, errors}
      end
    else
      {:error, :missing_session_scope}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  Stages and commits working changes in the target project repository.
  """
  def perform_commit(project_root, opts \\ []) do
    if project_root != File.cwd!() and git_repo?(project_root) do
      commit_msg = Keyword.get(opts, :message, "chore: session cancelled checkpoint commit")

      with :ok <- Tools.git_stage(:all, project_root, opts),
           {:ok, _} <-
             Tools.git_commit(commit_msg, project_root, Keyword.put(opts, :allow_empty, true)) do
        {:ok, :committed}
      else
        {:error, reason} -> {:error, reason}
      end
    else
      {:ok, :committed}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  # True when `path` is a git repository. `.git` may be a directory (normal clone)
  # or a file (linked worktree); bare checkouts have no `.git` entry at all,
  # so fall back to `git rev-parse`.
  defp git_repo?(path) do
    if File.exists?(Path.join(path, ".git")) do
      true
    else
      match?(
        {_, 0},
        System.cmd("git", ["rev-parse", "--git-dir"], cd: path, stderr_to_stdout: true)
      )
    end
  rescue
    _ -> false
  end

  defp trusted_project_id(%State{session: %{project_id: project_id}}), do: project_id

  defp trusted_project_id(%State{session_id: session_id}) do
    case Sessions.get_session(session_id) do
      %{project_id: project_id} -> project_id
      _ -> nil
    end
  end

  @doc """
  Executes the synchronous swarm coordination state machine.
  Returns `{:ok, final_message}` or `{:error, reason}`.
  """
  def run(session_id, user_prompt, opts \\ []) do
    case durable_swarm_owner_identity(opts) do
      :interactive ->
        run_with_interactive_ownership(session_id, user_prompt, opts)

      {:ok, identity} ->
        run_with_durable_ownership(session_id, user_prompt, opts, identity)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_run(session_id, user_prompt, opts) do
    session =
      try do
        Sessions.get_session!(session_id)
      rescue
        _ ->
          Sessions.get_session(session_id) || %Sessions.Session{id: session_id, status: "running"}
      end

    session = apply_execution_policy!(session, opts[:execution_policy])

    project_root =
      opts[:project_root] || (session.project && session.project.root_path) || File.cwd!()

    max_retries = bounded_max_retries(Keyword.get(opts, :max_retries, 3))

    # Subscribe to steering topic for mid-flight steering/control
    unless is_binary(opts[:run_id]) do
      PubSub.subscribe(IexCode.PubSub, "session:#{session_id}:steer")
    end

    if is_binary(opts[:run_id]) do
      PubSub.subscribe(IexCode.PubSub, "run:#{opts[:run_id]}:control")
    end

    # Honor a pause requested between task spawn and this subscribe — the early
    # {:pause, _} broadcast had no subscriber yet, so the persisted status is
    # the only reliable signal.
    pre_paused? =
      case opts[:run_id] && Runs.get_run(opts[:run_id]) do
        %{status: "paused"} ->
          true

        _ ->
          case Sessions.get_session(session_id) do
            %{status: "paused"} -> true
            _ -> false
          end
      end

    start_time_ms = System.monotonic_time(:millisecond)

    state = %State{
      session_id: session_id,
      run_id: opts[:run_id],
      session: session,
      project_root: project_root,
      user_prompt: user_prompt,
      allowed_tools: Keyword.get(opts, :allowed_tools, :all),
      workspace_lock_delegation: opts[:workspace_lock_delegation],
      run_lease_owner: opts[:run_lease_owner],
      run_attempt: opts[:run_attempt],
      run_lease_generation: opts[:run_lease_generation],
      run_lease_ms: opts[:run_lease_ms],
      execution_policy: opts[:execution_policy],
      control_barrier: opts[:control_barrier],
      max_retries: max_retries,
      start_time_ms: start_time_ms,
      stage_start_ms: start_time_ms,
      stage: :init,
      status: if(pre_paused?, do: :paused, else: :running)
    }

    state = state |> ensure_durable_run_active!() |> restore_durable_steering()

    if pre_paused? do
      broadcast(session_id, {:session_status_changed, "paused"})
    else
      broadcast(session_id, {:session_status_changed, "running"})
      update_db_session_status(session_id, "running")
    end

    state = state |> ensure_durable_user_message() |> attach_durable_fleet()

    # 1. Root Swarm Operation — created before the guarded region below so the
    # crash handler can still mark it failed (try-body bindings don't leak to catch).
    {:ok, root_op} = create_root_operation(session_id, user_prompt)
    state = %State{state | root_op_id: root_op.id}

    try do
      state = ensure_legacy_agents(state)

      broadcast_stage(
        state,
        :init,
        5,
        "Swarm initialized with #{fleet_size(state)} isolated OTP subagents."
      )

      state = await_control_barrier(state)

      # A pause that landed before subscribe: block until resumed (or cancelled;
      # cancellation throws {:swarm_cancelled, _, _} from inside the wait).
      state = state |> replay_claimed_controls() |> align_durable_control_state()

      state =
        if state.status == :paused do
          wait_for_resume_or_cancel(state)
        else
          check_steering_and_control(state)
        end

      # 2. Planning Phase
      state = run_planning_phase(state)
      state = check_steering_and_control(state)

      # 3. Exploration Phase
      state = run_exploration_phase(state)
      state = check_steering_and_control(state)

      # 4. Coding & Verification Phase with Self-Healing Feedback Loop
      state = run_coding_and_verification_loop(state)

      # 5. Final Synthesis & Assistant Message
      finish_swarm(state)
    catch
      {:durable_run_fenced, reason} ->
        Logger.warning(
          "[SwarmCoordinator] Durable run #{state.run_id} lost execution authority: #{inspect(reason)}"
        )

        {:error, {:durable_run_fenced, reason}}

      {:swarm_agent_phase_interrupted, role, reason, final_state} ->
        {:error, {:agent_phase_interrupted, role, reason, final_state.stage}}

      {:swarm_cancelled, action, final_state} ->
        {:ok, %{status: :stopped, action: action, cancelled: true, state: final_state}}

      # Any other throw, error or exit: clean up loudly instead of dying silently.
      kind, payload ->
        stacktrace = __STACKTRACE__
        handle_swarm_crash(session_id, state, kind, payload, stacktrace)

        case kind do
          :exit -> exit(payload)
          :throw -> throw(payload)
          _ -> reraise(payload, stacktrace)
        end
    end
  end

  defp handle_swarm_crash(session_id, state, kind, reason, stacktrace) do
    reason_str = Exception.format(kind, reason, stacktrace)

    Logger.error("[SwarmCoordinator] Swarm run crashed for session #{session_id}: #{reason_str}")

    stop_state_agents(state, "failed")
    perform_rollback(state.project_root, state)
    update_db_session_status(session_id, "failed")

    if state.root_op_id do
      Sessions.update_operation(state.root_op_id, %{
        status: "failed",
        progress: 100,
        result: "Swarm execution crashed: #{String.slice(reason_str, 0, 500)}",
        completed_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
    end

    broadcast_stage(%State{state | stage: :failed}, :failed, 100, "Swarm execution crashed.")
    broadcast(session_id, {:session_status_changed, "failed"})
  rescue
    e ->
      Logger.error(
        "[SwarmCoordinator] Crash cleanup itself failed for session #{session_id}: #{Exception.message(e)}"
      )
  end

  # ============================================================================
  # Real-Time Steering & Control Engine
  # ============================================================================

  defp check_steering_and_control(%State{session_id: session_id} = state) do
    state = ensure_durable_run_active!(state)

    receive do
      {:run_control, run_id, control_id, :steer, %{"guidance" => _steer_text}}
      when run_id == state.run_id ->
        next_state = reconcile_durable_steering(state, control_id, "durable run control")

        check_steering_and_control(next_state)

      {:run_control, run_id, control_id, :pause, _payload} when run_id == state.run_id ->
        if acknowledge_control(control_id, state, "pause") == :ok do
          Logger.info("[SwarmCoordinator] Durable run #{run_id} paused.")
          broadcast(session_id, {:session_status_changed, "paused"})
          wait_for_resume_or_cancel(%State{state | status: :paused})
        else
          check_steering_and_control(state)
        end

      {:run_control, run_id, control_id, :resume, _payload} when run_id == state.run_id ->
        next_state =
          if acknowledge_control(control_id, state, "resume") == :ok,
            do: %State{state | status: :running},
            else: state

        check_steering_and_control(next_state)

      {:run_control, run_id, :cancel, _payload} when run_id == state.run_id ->
        Logger.info("[SwarmCoordinator] Durable run #{run_id} cancelled.")
        handle_cancel_and_terminate(state, action: :rollback)

      {:steer_message, steer_text} ->
        state
        |> ingest_steering(steer_text, "session steering")
        |> check_steering_and_control()

      {:steer, steer_text} ->
        state
        |> ingest_steering(steer_text, "direct steering")
        |> check_steering_and_control()

      {:pause, ^session_id} ->
        Logger.info("[SwarmCoordinator] Session #{session_id} paused.")
        update_db_session_status(session_id, "paused")
        broadcast(session_id, {:session_status_changed, "paused"})
        state = %State{state | status: :paused}
        wait_for_resume_or_cancel(state)

      {:cancel, ^session_id, opts} ->
        Logger.info("[SwarmCoordinator] Session #{session_id} cancelled.")
        handle_cancel_and_terminate(state, opts)
    after
      0 ->
        case state |> replay_claimed_controls() |> align_durable_control_state() do
          %State{status: :paused} = paused -> wait_for_resume_or_cancel(paused)
          next_state -> next_state
        end
    end
  end

  # A deterministic safe-point used by concurrency tests and controlled
  # embedders. It is reached only after init-stage persistence has returned, so
  # the waiting coordinator cannot hold a checked-out database connection.
  # Monitoring the controller prevents an abandoned barrier from leaking a run.
  defp await_control_barrier(%State{control_barrier: {controller, reference}} = state)
       when is_pid(controller) and is_reference(reference) do
    monitor = Process.monitor(controller)
    send(controller, {:swarm_control_barrier, self(), reference})

    receive do
      {:release_swarm_control_barrier, ^reference} ->
        Process.demonitor(monitor, [:flush])
        %State{state | control_barrier: nil}

      {:DOWN, ^monitor, :process, ^controller, _reason} ->
        throw({:durable_run_fenced, :control_barrier_owner_down})
    end
  end

  defp await_control_barrier(state), do: state

  defp wait_for_resume_or_cancel(%State{session_id: session_id} = state) do
    state = ensure_durable_run_active!(state)

    receive do
      {:run_control, run_id, control_id, :resume, _payload} when run_id == state.run_id ->
        if acknowledge_control(control_id, state, "resume") == :ok do
          Logger.info("[SwarmCoordinator] Durable run #{run_id} resumed.")
          broadcast(session_id, {:session_status_changed, "running"})

          case %State{state | status: :running}
               |> replay_claimed_controls()
               |> align_durable_control_state() do
            %State{status: :paused} = paused -> wait_for_resume_or_cancel(paused)
            resumed -> resumed
          end
        else
          wait_for_resume_or_cancel(state)
        end

      {:run_control, run_id, control_id, :pause, _payload} when run_id == state.run_id ->
        acknowledge_control(control_id, state, "pause")
        wait_for_resume_or_cancel(state)

      {:run_control, run_id, :cancel, _payload} when run_id == state.run_id ->
        state = ensure_durable_run_active!(state)
        Logger.info("[SwarmCoordinator] Durable run #{run_id} cancelled while paused.")
        handle_cancel_and_terminate(state, action: :rollback)

      {:run_control, run_id, control_id, :steer, %{"guidance" => _steer_text}}
      when run_id == state.run_id ->
        state
        |> reconcile_durable_steering(control_id, "durable run control while paused")
        |> wait_for_resume_or_cancel()

      {:resume, ^session_id} ->
        Logger.info("[SwarmCoordinator] Session #{session_id} resumed.")
        update_db_session_status(session_id, "running")
        broadcast(session_id, {:session_status_changed, "running"})
        %State{state | status: :running}

      # Swallow duplicate pause messages buffered while already paused, so a
      # stale pause cannot re-pause the swarm after a single resume.
      {:pause, ^session_id} ->
        Logger.info(
          "[SwarmCoordinator] Ignoring duplicate pause while already paused for session #{session_id}."
        )

        wait_for_resume_or_cancel(state)

      {:cancel, ^session_id, opts} ->
        Logger.info("[SwarmCoordinator] Session #{session_id} cancelled while paused.")
        handle_cancel_and_terminate(state, opts)

      {:steer_message, steer_text} ->
        state
        |> ingest_steering(steer_text, "session steering while paused")
        |> wait_for_resume_or_cancel()

      {:steer, steer_text} ->
        state
        |> ingest_steering(steer_text, "direct steering while paused")
        |> wait_for_resume_or_cancel()
    after
      200 ->
        case state |> replay_claimed_controls() |> align_durable_control_state() do
          %State{status: :running} = resumed -> resumed
          next_state -> wait_for_resume_or_cancel(next_state)
        end
    end
  end

  defp ingest_steering(%State{session_id: session_id} = state, steer_text, _source) do
    steer_text = normalize_steering(steer_text)

    Logger.info(
      "[SwarmCoordinator] Ingested interactive steering session=#{session_id} bytes=#{byte_size(steer_text)}"
    )

    duplicate? = steer_text == "" or steer_text in state.steer_directives
    addition = "\n\n[Real-time User Guidance]: " <> steer_text

    new_prompt =
      if duplicate? or
           byte_size(state.user_prompt) + byte_size(addition) > @max_steering_context_bytes,
         do: state.user_prompt,
         else: state.user_prompt <> addition

    directives =
      if duplicate? do
        state.steer_directives
      else
        [steer_text | state.steer_directives] |> Enum.take(@max_steering_directives)
      end

    if steer_text != "" and not duplicate? do
      broadcast(
        session_id,
        {:swarm_steered,
         %{session_id: session_id, steering: steer_text, updated_prompt: new_prompt}}
      )
    end

    %State{
      state
      | user_prompt: new_prompt,
        steer_directives: directives
    }
  end

  defp start_swarm_task(session_id, user_prompt, project_root, run_opts, register_owner?) do
    if project_root do
      IexCode.Tools.MultiPatch.Snapshot.claim_unscoped(project_root, session_id)
    end

    parent = self()
    start_ref = make_ref()
    task_supervisor = Keyword.get(run_opts, :task_supervisor, IexCode.TaskSupervisor)

    start_result =
      try do
        Task.Supervisor.start_child(task_supervisor, fn ->
          allow_sandbox(parent, self())

          registration =
            if register_owner? do
              AgentRegistry.register_swarm_owner(
                session_id,
                swarm_owner_metadata(run_opts)
              )
            else
              {:ok, :durable_run}
            end

          case registration do
            {:ok, _metadata} ->
              send(parent, {start_ref, :registered, self()})

              try do
                execute_swarm(session_id, user_prompt, run_opts)
              after
                if register_owner?, do: AgentRegistry.unregister_swarm_owner(session_id)
              end

            {:error, {:already_registered, owner}} ->
              send(parent, {start_ref, :already_registered, owner})
          end
        end)
      catch
        :exit, reason -> {:error, reason}
      end

    await_swarm_start(start_result, start_ref, task_supervisor, session_id)
  end

  defp await_swarm_start({:ok, task_pid}, start_ref, task_supervisor, session_id) do
    monitor = Process.monitor(task_pid)

    receive do
      {^start_ref, :registered, ^task_pid} ->
        Process.demonitor(monitor, [:flush])
        {:ok, task_pid}

      {^start_ref, :already_registered, owner} when is_pid(owner) ->
        Process.demonitor(monitor, [:flush])

        case AgentRegistry.swarm_owner_registration(session_id) do
          {:ok, ^owner, metadata} ->
            {:error, {:session_swarm_owned, metadata[:run_id] || :interactive}}

          {:error, {:swarm_owner_metadata_unavailable, ^owner, _reason}} ->
            {:error, :swarm_owner_metadata_unavailable}

          :none ->
            {:error, :session_swarm_owned}
        end

      {:DOWN, ^monitor, :process, ^task_pid, reason} ->
        {:error, {:swarm_start_failed, reason}}
    after
      @swarm_start_timeout ->
        Process.demonitor(monitor, [:flush])
        _ = Task.Supervisor.terminate_child(task_supervisor, task_pid)
        {:error, :swarm_start_timeout}
    end
  end

  defp await_swarm_start({:error, reason}, _start_ref, _task_supervisor, _session_id),
    do: {:error, reason}

  defp normalize_steering(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.slice(0, @max_steering_bytes)
  end

  defp normalize_steering(_value), do: ""

  defp swarm_owner_identity(opts) do
    %{
      run_id: opts[:run_id],
      run_attempt: opts[:run_attempt],
      lease_generation: opts[:run_lease_generation],
      lease_owner: opts[:run_lease_owner],
      ownership_token: opts[:ownership_token]
    }
  end

  defp swarm_owner_metadata(opts) do
    opts
    |> swarm_owner_identity()
    |> Map.put(:started_at, System.system_time())
  end

  defp durable_swarm_owner_identity(opts) do
    case opts[:run_id] do
      run_id when is_binary(run_id) ->
        identity = swarm_owner_identity(opts)

        if is_integer(identity.run_attempt) and identity.run_attempt > 0 and
             is_integer(identity.lease_generation) and identity.lease_generation > 0 and
             is_binary(identity.lease_owner) and String.trim(identity.lease_owner) != "" do
          {:ok, identity}
        else
          {:error, :invalid_swarm_owner_identity}
        end

      _run_id ->
        :interactive
    end
  end

  defp validate_durable_swarm_owner_identity(opts) do
    case durable_swarm_owner_identity(opts) do
      :interactive -> :ok
      {:ok, _identity} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp run_with_durable_ownership(session_id, user_prompt, opts, identity) do
    case AgentRegistry.register_swarm_owner(
           session_id,
           Map.put(identity, :started_at, System.system_time())
         ) do
      {:ok, _metadata} ->
        try do
          execute_swarm(session_id, user_prompt, opts)
        after
          AgentRegistry.unregister_swarm_owner(session_id)
        end

      {:error, {:already_registered, _owner}} ->
        {:error, :session_swarm_owned}
    end
  end

  defp run_with_interactive_ownership(session_id, user_prompt, opts) do
    case AgentRegistry.register_swarm_owner(session_id, swarm_owner_metadata(opts)) do
      {:ok, _metadata} ->
        try do
          execute_swarm(session_id, user_prompt, opts)
        after
          AgentRegistry.unregister_swarm_owner(session_id)
        end

      {:error, {:already_registered, _owner}} ->
        {:error, :session_swarm_owned}
    end
  end

  defp execute_swarm(session_id, user_prompt, opts) do
    do_run(session_id, user_prompt, opts)
  catch
    {:durable_run_fenced, reason} ->
      Logger.warning(
        "[SwarmCoordinator] Durable run #{opts[:run_id]} failed preflight authority: #{inspect(reason)}"
      )

      {:error, {:durable_run_fenced, reason}}
  end

  defp acknowledge_control(control_id, state, action) do
    with {:ok, control} <- validate_control(control_id, state, action) do
      resolve_or_accept_control(control, state, action)
    else
      _ -> :stale
    end
  end

  defp validate_control(control_id, state, action) do
    with %{
           run_id: run_id,
           kind: kind,
           worker_id: worker_id,
           target_attempt: target_attempt,
           target_generation: target_generation,
           claim_generation: claim_generation
         } = control <-
           Runs.get_control(control_id),
         true <- run_id == state.run_id and kind == action,
         true <- target_attempt == state.run_attempt,
         true <- target_generation == state.run_lease_generation,
         true <- claim_generation == state.run_lease_generation,
         true <- worker_id == state.run_lease_owner,
         %IexCode.Runs.Run{
           status: run_status,
           attempt: ^target_attempt,
           lease_generation: ^target_generation,
           lease_owner: ^worker_id,
           lease_expires_at: %DateTime{} = lease_expires_at
         } <- Runs.get_run(run_id),
         true <- run_status in ["running", "paused"],
         true <- DateTime.compare(lease_expires_at, DateTime.utc_now()) == :gt do
      {:ok, control}
    else
      _ -> {:error, :stale}
    end
  end

  # The control row is already the durable, idempotent steering intent. Apply
  # its persisted payload to memory before resolving the durable receipt so a
  # crash can only leave the control claimed for safe replay, never applied but
  # absent from the coordinator state.
  @doc false
  def reconcile_durable_steering(%State{} = state, control_id, source \\ "durable run control")
      when is_binary(control_id) and is_binary(source) do
    case validate_control(control_id, state, "steer") do
      {:ok, control} ->
        guidance = value(control.payload, "guidance")

        case persist_durable_steering(state, control, guidance) do
          :ok ->
            next_state =
              if is_binary(guidance), do: put_steering(state, guidance), else: state

            case resolve_or_accept_control(control, next_state, "steer") do
              :ok ->
                notify_durable_steering(state, next_state, guidance, source)
                next_state

              :stale ->
                state
            end

          {:error, reason} ->
            Logger.warning(
              "Could not persist durable swarm steering #{control.id}: #{inspect(reason)}"
            )

            state
        end

      {:error, :stale} ->
        state
    end
  end

  defp persist_durable_steering(state, control, guidance) when is_binary(guidance) do
    attrs = %{
      session_id: state.session_id,
      role: "user",
      agent_name: "User (Steer)",
      content: "Steering guidance: " <> normalize_steering(guidance),
      metadata: %{
        "run_id" => state.run_id,
        "control_id" => control.id,
        "intent" => "steer"
      }
    }

    case Sessions.create_message_once(attrs, "swarm-steer:#{control.id}") do
      {:ok, message, :created} ->
        broadcast(state.session_id, {:message_created, message})
        :ok

      {:ok, _message, :existing} ->
        :ok

      {:error, _reason} = error ->
        error
    end
  end

  defp persist_durable_steering(_state, _control, _guidance),
    do: {:error, :invalid_steering_guidance}

  defp notify_durable_steering(previous, updated, guidance, _source) when is_binary(guidance) do
    normalized = normalize_steering(guidance)

    if normalized != "" and normalized not in previous.steer_directives and
         normalized in updated.steer_directives do
      Logger.info(
        "[SwarmCoordinator] Ingested durable steering run=#{updated.run_id} bytes=#{byte_size(normalized)}"
      )

      broadcast(
        updated.session_id,
        {:swarm_steered,
         %{
           session_id: updated.session_id,
           steering: normalized,
           updated_prompt: updated.user_prompt
         }}
      )
    end

    :ok
  end

  defp notify_durable_steering(_previous, _updated, _guidance, _source), do: :ok

  # Legacy pause/resume transitions atomically resolve their receipt in the
  # dispatcher before delivery. Steering remains claimed until the coordinator
  # has applied the durable control payload to its state. Both paths are safe
  # only after the exact lineage checks in validate_control/3 above.
  defp resolve_or_accept_control(%{status: "applied"}, _state, _action), do: :ok

  defp resolve_or_accept_control(%{status: "claimed"} = control, state, action) do
    case Runs.resolve_control(
           control,
           "applied",
           %{
             "action" => action,
             "stage" => to_string(state.stage),
             "acknowledged_by" => "swarm_coordinator"
           },
           run_id: control.run_id,
           worker_id: control.worker_id,
           kind: control.kind,
           target_attempt: state.run_attempt,
           target_generation: state.run_lease_generation,
           claim_generation: state.run_lease_generation
         ) do
      {:ok, _resolved} -> :ok
      {:error, _reason} -> :stale
    end
  end

  defp resolve_or_accept_control(_control, _state, _action), do: :stale

  defp replay_claimed_controls(%State{run_id: run_id} = state) when is_binary(run_id) do
    case Runs.list_controls(run_id, status: "claimed", limit: 1) do
      [%{kind: "steer"} = control] ->
        next_state =
          reconcile_durable_steering(state, control.id, "durable control poll")

        case Runs.get_control(control.id) do
          %{status: "applied"} -> replay_claimed_controls(next_state)
          _unresolved -> state
        end

      [%{kind: "pause"} = control] ->
        if acknowledge_control(control.id, state, "pause") == :ok do
          replay_claimed_controls(%State{state | status: :paused})
        else
          state
        end

      [%{kind: "resume"} = control] ->
        if acknowledge_control(control.id, state, "resume") == :ok do
          replay_claimed_controls(%State{state | status: :running})
        else
          state
        end

      _ ->
        state
    end
  end

  defp replay_claimed_controls(state), do: state

  @doc false
  def restore_durable_steering(%State{run_id: run_id} = state) when is_binary(run_id) do
    run_id
    |> Runs.list_controls(status: "applied", kind: "steer", limit: 1_000)
    |> Enum.take(-@max_steering_directives)
    |> Enum.reduce(state, fn control, current ->
      guidance = value(control.payload, "guidance")
      if is_binary(guidance), do: put_steering(current, guidance), else: current
    end)
  end

  def restore_durable_steering(state), do: state

  defp put_steering(state, steer_text) do
    steer_text = normalize_steering(steer_text)
    duplicate? = steer_text == "" or steer_text in state.steer_directives
    addition = "\n\n[Real-time User Guidance]: " <> steer_text

    new_prompt =
      if duplicate? or
           byte_size(state.user_prompt) + byte_size(addition) > @max_steering_context_bytes,
         do: state.user_prompt,
         else: state.user_prompt <> addition

    directives =
      if duplicate?,
        do: state.steer_directives,
        else: [steer_text | state.steer_directives] |> Enum.take(@max_steering_directives)

    %State{state | user_prompt: new_prompt, steer_directives: directives}
  end

  defp align_durable_control_state(
         %State{
           run_id: run_id,
           run_attempt: attempt,
           run_lease_generation: generation,
           run_lease_owner: owner
         } = state
       )
       when is_binary(run_id) do
    case Runs.get_run(run_id) do
      %{status: "paused", attempt: ^attempt, lease_generation: ^generation, lease_owner: ^owner} ->
        %State{state | status: :paused}

      %{status: "running", attempt: ^attempt, lease_generation: ^generation, lease_owner: ^owner} ->
        %State{state | status: :running}

      _ ->
        state
    end
  end

  defp align_durable_control_state(state), do: state

  defp ensure_durable_run_active!(
         %State{
           run_id: run_id,
           run_lease_owner: owner,
           run_attempt: attempt,
           run_lease_generation: generation
         } = state
       )
       when is_binary(run_id) do
    case Runs.get_run(run_id) do
      %IexCode.Runs.Run{
        status: status,
        lease_owner: ^owner,
        attempt: ^attempt,
        lease_generation: ^generation,
        lease_expires_at: %DateTime{} = lease_expires_at
      }
      when status in ["failed", "cancelled", "interrupted"] ->
        if DateTime.compare(lease_expires_at, DateTime.utc_now()) == :gt do
          stop_state_agents(state, status)
          _ = perform_rollback(state.project_root, state)
          throw({:swarm_cancelled, :durable_run_terminal, state})
        else
          throw({:durable_run_fenced, :lease_expired})
        end

      %IexCode.Runs.Run{
        status: status,
        lease_owner: ^owner,
        attempt: ^attempt,
        lease_generation: ^generation,
        lease_expires_at: %DateTime{} = lease_expires_at
      }
      when status in ["running", "paused"] ->
        if DateTime.compare(lease_expires_at, DateTime.utc_now()) == :gt do
          state
        else
          throw({:durable_run_fenced, :lease_expired})
        end

      _stale_or_missing ->
        throw({:durable_run_fenced, :lease_not_owned})
    end
  end

  defp ensure_durable_run_active!(state), do: state

  defp value(map, key), do: Map.get(map || %{}, key) || Map.get(map || %{}, to_string(key))

  defp attach_durable_fleet(
         %State{
           run_id: run_id,
           run_lease_owner: owner,
           run_attempt: attempt,
           run_lease_generation: generation
         } = state
       )
       when is_binary(run_id) do
    case Runs.get_run(run_id) do
      %IexCode.Runs.Run{
        lease_owner: ^owner,
        attempt: ^attempt,
        lease_generation: ^generation
      } = run ->
        case FleetSupervisor.attach(run,
               session: state.session,
               project_root: state.project_root,
               allowed_tools: state.allowed_tools,
               workspace_lock_delegation: state.workspace_lock_delegation
             ) do
          {:ok, agents} -> %State{state | fleet_agents: agents}
          {:error, reason} -> raise "durable fleet failed to attach: #{inspect(reason)}"
        end

      _stale_or_missing ->
        throw({:durable_run_fenced, :lease_not_owned})
    end
  end

  defp attach_durable_fleet(state), do: state

  defp apply_execution_policy!(session, nil), do: session

  defp apply_execution_policy!(session, policy) when is_map(policy) do
    provider =
      Map.get(policy, "model_provider") || Map.get(policy, :model_provider) ||
        session.model_provider

    model = Map.get(policy, "model_name") || Map.get(policy, :model_name) || session.model_name

    temperature =
      Map.get(policy, "temperature") || Map.get(policy, :temperature) || session.temperature

    temperature = if is_number(temperature), do: temperature * 1.0, else: temperature

    cond do
      provider not in ["openai", "anthropic"] ->
        raise ArgumentError, "invalid snapshotted model provider"

      not Limits.valid_model_name?(model) ->
        raise ArgumentError, "invalid snapshotted model name"

      not is_float(temperature) or temperature < 0.0 or temperature > 2.0 ->
        raise ArgumentError, "invalid snapshotted model temperature"

      true ->
        %{session | model_provider: provider, model_name: model, temperature: temperature}
    end
  end

  defp apply_execution_policy!(_session, _policy),
    do: raise(ArgumentError, "invalid snapshotted execution policy")

  defp ensure_durable_user_message(%State{run_id: run_id} = state) when is_binary(run_id) do
    case run_id |> Runs.get_run() |> Sessions.ensure_run_user_message() do
      {:ok, message, :created} ->
        broadcast(state.session_id, {:message_created, message})

      {:ok, _message, :existing} ->
        :ok

      {:error, reason} ->
        raise "could not persist durable swarm user turn: #{inspect(reason)}"
    end

    state
  end

  defp ensure_durable_user_message(state), do: state

  defp bounded_max_retries(value) when is_integer(value), do: value |> max(0) |> min(10)
  defp bounded_max_retries(_value), do: 3

  defp ensure_legacy_agents(%State{run_id: run_id, fleet_agents: agents} = state)
       when is_binary(run_id) and agents != [],
       do: state

  defp ensure_legacy_agents(%State{run_id: run_id}) when is_binary(run_id),
    do: raise("durable run has no active fleet")

  defp ensure_legacy_agents(%State{} = state) do
    for role <- [:planner, :explorer, :coder, :verifier] do
      {:ok, _pid} =
        AgentSupervisor.start_agent(state.session_id, role,
          session: state.session,
          project_root: state.project_root
        )
    end

    state
  end

  defp fleet_size(%State{fleet_agents: []}), do: 4
  defp fleet_size(%State{fleet_agents: agents}), do: length(agents)

  defp invoke_role(state, role, fun), do: invoke_role(state, role, fun, true)

  defp invoke_role(%State{run_id: run_id, fleet_agents: agents}, role, fun, drain_steering?)
       when is_binary(run_id) and is_function(fun, 2) and is_boolean(drain_steering?) do
    case Enum.find(agents, &(&1.role == role)) do
      %{agent_id: agent_id} ->
        FleetRuntime.invoke_agent(run_id, agent_id, fn current ->
          directives =
            if drain_steering?, do: FleetManager.drain_steering(run_id, agent_id), else: []

          fun.(current.pid, directives)
        end)

      nil ->
        {:error, {:agent_missing, role}}
    end
  end

  defp invoke_role(%State{session_id: session_id}, _role, fun, _drain_steering?)
       when is_function(fun, 2) do
    safe_agent_invocation(fn -> fun.(session_id, []) end)
  end

  defp safe_agent_invocation(fun) do
    fun.()
  catch
    :exit, _reason -> {:error, :agent_invocation_interrupted}
  end

  defp explorer_targets(%State{fleet_agents: []} = state),
    do: [%{pid: state.session_id, agent_id: nil, position: 0}]

  defp explorer_targets(%State{fleet_agents: agents}) do
    agents
    |> Enum.filter(&(&1.role == :explorer))
    |> Enum.sort_by(& &1.position)
  end

  defp stop_state_agents(
         %State{
           run_id: run_id,
           run_lease_owner: owner,
           run_attempt: attempt,
           run_lease_generation: generation
         },
         status
       )
       when is_binary(run_id) do
    case AgentRegistry.whereis_fleet(run_id, :manager) do
      nil ->
        :ok

      _pid ->
        FleetManager.stop(run_id, status,
          lease_owner: owner,
          run_attempt: attempt,
          lease_generation: generation
        )
    end
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp stop_state_agents(%State{session_id: session_id}, _status),
    do: AgentSupervisor.stop_all_agents(session_id)

  defp handle_cancel_and_terminate(%State{session_id: session_id} = state, opts) do
    state = ensure_durable_run_active!(state)
    action = Keyword.get(opts, :action, :rollback)
    project_root = state.project_root

    # Cleanly stop all subagents
    stop_state_agents(state, "cancelled")

    case action do
      :rollback ->
        case perform_rollback(project_root, state) do
          {:ok, :rolled_back} ->
            :ok

          {:error, reason} ->
            Logger.error(
              "[SwarmCoordinator] Rollback failed during cancel for session #{session_id}: #{inspect(reason)}"
            )
        end

      :commit ->
        commit_opts =
          opts
          |> Keyword.put(:project_id, trusted_project_id(state))
          |> Keyword.put(:run_id, state.run_id)
          |> Keyword.put(:session_id, state.session_id)

        case perform_commit(project_root, commit_opts) do
          {:ok, :committed} ->
            :ok

          {:error, reason} ->
            Logger.error(
              "[SwarmCoordinator] Commit failed during cancel for session #{session_id}: #{inspect(reason)}"
            )
        end

      _ ->
        :ok
    end

    if state.root_op_id do
      Sessions.update_operation(state.root_op_id, %{
        status: "failed",
        progress: 100,
        result: "Swarm execution cancelled by user (#{action})",
        completed_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
    end

    update_db_session_status(session_id, "stopped")

    case Sessions.create_message(%{
           session_id: session_id,
           role: "assistant",
           agent_name: "Swarm Coordinator",
           content:
             "🛑 **Session Stopped**: Swarm execution cancelled by user with action `#{action}`."
         }) do
      {:ok, cancel_msg} -> broadcast(session_id, {:message_created, cancel_msg})
      _ -> :ok
    end

    broadcast(session_id, {:session_status_changed, "stopped"})
    broadcast(session_id, {:session_cancelled, %{session_id: session_id, action: action}})

    throw({:swarm_cancelled, action, %State{state | status: :stopped}})
  end

  # ============================================================================
  # Swarm Stages
  # ============================================================================

  defp run_planning_phase(%State{user_prompt: prompt, root_op_id: root_op_id} = state) do
    broadcast_stage(state, :planning, 15, "Planner: Decomposing architecture & execution plan...")

    plan_res =
      invoke_role(state, :planner, fn target, targeted_steering ->
        PlannerAgent.plan(
          target,
          prompt,
          parent_op_id: root_op_id,
          project_root: state.project_root,
          run_id: state.run_id,
          steer_directives: state.steer_directives ++ targeted_steering,
          allowed_tools: state.allowed_tools,
          execution_policy: state.execution_policy,
          workspace_lock_delegation: state.workspace_lock_delegation
        )
      end)

    plan_text =
      case plan_res do
        {:ok, text} -> text
        {:error, reason} -> abort_durable_agent_phase!(state, :planner, reason)
      end

    broadcast_stage(state, :planning, 25, "Planner: Execution plan formulated.")
    %State{state | plan: plan_text, stage: :planning}
  end

  defp run_exploration_phase(%State{user_prompt: prompt, root_op_id: root_op_id} = state) do
    broadcast_stage(
      state,
      :exploring,
      35,
      "Explorer: Scanning codebase for relevant files & AST symbols..."
    )

    targets = explorer_targets(state)

    summary_text =
      targets
      |> Enum.with_index()
      |> Task.async_stream(
        fn {entry, index} ->
          focus =
            "Explorer shard #{index + 1}/#{length(targets)}: inspect a distinct relevant area."

          invoke_explorer(state, entry, fn target, targeted_steering ->
            guidance =
              (state.steer_directives ++ targeted_steering)
              |> Enum.map_join("\n", &"- #{&1}")

            ExplorerAgent.explore(
              target,
              prompt <> "\n\n" <> focus <> "\n" <> guidance,
              parent_op_id: root_op_id,
              project_root: state.project_root,
              run_id: state.run_id,
              allowed_tools: state.allowed_tools,
              workspace_lock_delegation: state.workspace_lock_delegation
            )
          end)
        end,
        max_concurrency: max(length(targets), 1),
        ordered: true,
        timeout: :infinity
      )
      |> Enum.with_index()
      |> Enum.map_join("\n\n", fn
        {{:ok, {:ok, text}}, index} ->
          "Explorer #{index + 1}:\n#{text}"

        {{:ok, {:error, reason}}, _index} ->
          abort_durable_agent_phase!(state, :explorer, reason)

        {{:exit, reason}, _index} ->
          abort_durable_agent_phase!(state, :explorer, reason)
      end)

    broadcast_stage(state, :exploring, 45, "Explorer: Codebase context synthesized.")
    %State{state | explorer_context: summary_text, stage: :exploring}
  end

  defp invoke_explorer(%State{run_id: run_id}, %{agent_id: agent_id}, fun)
       when is_binary(run_id) do
    FleetRuntime.invoke_agent(run_id, agent_id, fn current ->
      fun.(current.pid, FleetManager.drain_steering(run_id, agent_id))
    end)
  end

  defp invoke_explorer(_state, %{pid: target}, fun) do
    safe_agent_invocation(fn -> fun.(target, []) end)
  end

  defp run_coding_and_verification_loop(%State{} = state) do
    do_coding_and_verification_loop(state, 0)
  end

  defp do_coding_and_verification_loop(%State{} = state, iteration) do
    state = check_steering_and_control(state)
    session_id = state.session_id
    project_root = state.project_root
    root_op_id = state.root_op_id
    prompt = state.user_prompt

    progress_pct = min(75, 45 + iteration * 10)

    # Step A: Coder Phase
    msg =
      if iteration == 0 do
        "Coder: Generating implementation and atomic patches..."
      else
        "Coder: Self-healing iteration #{iteration}/#{state.max_retries}: Applying targeted fixes..."
      end

    broadcast_stage(%State{state | iteration: iteration}, :coding, progress_pct, msg)

    coder_opts = [
      session_id: session_id,
      run_id: state.run_id,
      parent_op_id: root_op_id,
      project_root: project_root,
      plan: state.plan,
      context: state.explorer_context,
      diagnostics: state.verifier_result,
      steer_directives: state.steer_directives,
      allowed_tools: state.allowed_tools,
      execution_policy: state.execution_policy,
      workspace_lock_delegation: state.workspace_lock_delegation
    ]

    coder_res =
      invoke_role(state, :coder, fn coder_target, coder_steering ->
        CoderAgent.code(
          coder_target,
          prompt,
          Keyword.update!(coder_opts, :steer_directives, &(&1 ++ coder_steering))
        )
      end)

    coder_text =
      case coder_res do
        {:ok, text} -> text
        {:error, reason} -> abort_durable_agent_phase!(state, :coder, reason)
      end

    state = %State{state | coder_result: coder_text, iteration: iteration}
    state = check_steering_and_control(state)

    # Step B: Verifier Phase
    verify_progress = min(95, 75 + iteration * 5)

    broadcast_stage(
      state,
      :verifying,
      verify_progress,
      "Verifier: Checking compilation and test suite..."
    )

    verify_res = invoke_verifier(state, root_op_id, project_root)

    state = check_steering_and_control(state)

    case verify_res do
      {:ok, summary_map} ->
        # Verification Cleanly Passed!
        broadcast_stage(
          state,
          :complete,
          100,
          "Verification passed: All tests and compilation clean."
        )

        %State{state | verifier_result: summary_map, status: :completed, stage: :complete}

      {:error, {:verification_failed, diagnostics}} ->
        # Verification failed! Check retry condition & cycle detection
        # Hash deterministic semantic fields so recurring errors with duration
        # jitter are detected as cycles immediately.
        err_signature = compute_error_signature(diagnostics)

        if MapSet.member?(state.error_signatures, err_signature) or iteration >= state.max_retries do
          # Terminate loop (cycle detected or exceeded max retries)
          term_msg =
            if iteration >= state.max_retries do
              "Verification failed after #{state.max_retries} self-healing retries."
            else
              "Self-healing cycle detected. Halting loop."
            end

          broadcast_stage(state, :failed, 100, term_msg)
          %State{state | verifier_result: diagnostics, status: :failed, stage: :failed}
        else
          # Apply instant auto-fix heuristics if applicable
          auto_fix_res =
            AutoFix.apply_auto_fix(project_root, diagnostics,
              session_id: session_id,
              project_id: trusted_project_id(state),
              run_id: state.run_id,
              allowed_tools: state.allowed_tools
            )

          auto_fix_summary =
            case auto_fix_res do
              {:ok, summary} -> "AutoFix applied #{summary.applied} patch(es)"
              _ -> nil
            end

          new_sigs = MapSet.put(state.error_signatures, err_signature)

          new_state = %State{
            state
            | verifier_result: diagnostics,
              error_signatures: new_sigs,
              history: [{iteration, diagnostics, auto_fix_summary} | state.history]
          }

          case auto_fix_res do
            {:ok, %{applied: applied}} when applied > 0 ->
              # Direct re-verification optimization: AutoFix applied candidate proposals directly,
              # immediately verify to save latency if clean.
              broadcast_stage(
                new_state,
                :verifying,
                min(95, 75 + (iteration + 1) * 5),
                "AutoFix applied #{applied} fix(es). Re-verifying directly..."
              )

              verify_res = invoke_verifier(state, root_op_id, project_root)

              case verify_res do
                {:ok, summary_map} ->
                  broadcast_stage(
                    new_state,
                    :complete,
                    100,
                    "Verification passed: All tests and compilation clean."
                  )

                  %State{
                    new_state
                    | verifier_result: summary_map,
                      status: :completed,
                      stage: :complete,
                      iteration: iteration + 1
                  }

                {:error, {:verification_failed, new_diagnostics}} ->
                  new_err_sig = compute_error_signature(new_diagnostics)

                  if MapSet.member?(new_state.error_signatures, new_err_sig) or
                       iteration + 1 >= new_state.max_retries do
                    term_msg =
                      if iteration + 1 >= new_state.max_retries do
                        "Verification failed after #{new_state.max_retries} self-healing retries."
                      else
                        "Self-healing cycle detected. Halting loop."
                      end

                    broadcast_stage(new_state, :failed, 100, term_msg)

                    %State{
                      new_state
                      | verifier_result: new_diagnostics,
                        status: :failed,
                        stage: :failed,
                        iteration: iteration + 1
                    }
                  else
                    do_coding_and_verification_loop(
                      %State{
                        new_state
                        | verifier_result: new_diagnostics,
                          error_signatures: MapSet.put(new_state.error_signatures, new_err_sig)
                      },
                      iteration + 1
                    )
                  end

                {:error, reason} ->
                  broadcast_stage(
                    new_state,
                    :failed,
                    100,
                    "Verifier encountered unexpected error: #{inspect(reason)}"
                  )

                  %State{
                    new_state
                    | verifier_result: %{summary: inspect(reason)},
                      status: :failed,
                      stage: :failed,
                      iteration: iteration + 1
                  }
              end

            _ ->
              do_coding_and_verification_loop(new_state, iteration + 1)
          end
        end

      {:error, reason} ->
        broadcast_stage(
          state,
          :failed,
          100,
          "Verifier encountered unexpected error: #{inspect(reason)}"
        )

        %State{
          state
          | verifier_result: %{summary: inspect(reason)},
            status: :failed,
            stage: :failed
        }
    end
  end

  defp invoke_verifier(state, root_op_id, project_root) do
    invoke_role(
      state,
      :verifier,
      fn target, _targeted_steering ->
        VerifierAgent.verify(
          target,
          parent_op_id: root_op_id,
          project_root: project_root,
          run_id: state.run_id,
          allowed_tools: state.allowed_tools,
          workspace_lock_delegation: state.workspace_lock_delegation
        )
      end,
      false
    )
  end

  # Interactive legacy sessions historically degrade missing agent responses into notes.
  # Durable runs must instead stop at the phase boundary: continuing after an agent lease
  # or invocation was interrupted could let a later mutating phase run without its declared
  # prerequisite. An explicit targeted restart can service a later invocation, but this
  # interrupted call is never replayed implicitly.
  defp abort_durable_agent_phase!(%State{run_id: run_id} = state, role, reason)
       when is_binary(run_id) do
    stop_state_agents(state, "interrupted")
    _ = perform_rollback(state.project_root, state)

    broadcast_stage(
      %State{state | stage: :failed, status: :failed},
      :failed,
      100,
      "#{String.capitalize(to_string(role))} invocation was interrupted; explicit retry is required."
    )

    throw({:swarm_agent_phase_interrupted, role, reason, state})
  end

  defp abort_durable_agent_phase!(_state, role, reason),
    do: "#{String.capitalize(to_string(role))} note: #{inspect(reason)}"

  defp finish_swarm(%State{session_id: session_id} = state) do
    # Cleanup subagent processes for this session
    stop_state_agents(state, if(state.status == :completed, do: "completed", else: "failed"))

    verifier_summary =
      case state.verifier_result do
        %{summary: s} -> s
        other -> inspect(other)
      end

    steer_summary =
      if state.steer_directives != [] do
        guidance =
          state.steer_directives
          |> Enum.reverse()
          |> Enum.map(&"- #{&1}")
          |> Enum.join("\n")

        "\n\n**🧭 User Steering Applied**:\n#{guidance}"
      else
        ""
      end

    final_content =
      """
      ### 🐝 Swarm Execution Complete

      **🎯 Plan & Objective**:
      #{state.plan}

      **🔍 Exploration Findings**:
      #{state.explorer_context}

      **💻 Implementation**:
      #{state.coder_result}

      **🧪 Verification & Quality Check**:
      #{verifier_summary}#{steer_summary}
      """

    final_msg =
      case Sessions.create_message(%{
             session_id: session_id,
             role: "assistant",
             agent_name: "Swarm Coordinator",
             content: final_content,
             metadata: %{
               swarm_mode: true,
               status: state.status,
               iterations: state.iteration,
               steering_count: length(state.steer_directives)
             }
           }) do
        {:ok, msg} ->
          broadcast(session_id, {:message_created, msg})
          msg

        {:error, reason} ->
          Logger.error(
            "[SwarmCoordinator] Failed to persist final swarm message for session #{session_id}: #{inspect(reason)}"
          )

          %{id: nil, role: "assistant", content: final_content}
      end

    # Complete root operation
    if state.root_op_id do
      duration = System.monotonic_time(:millisecond) - state.start_time_ms

      case Sessions.update_operation(state.root_op_id, %{
             status: if(state.status == :completed, do: "completed", else: "failed"),
             progress: 100,
             result:
               if(state.status == :completed,
                 do: "Swarm execution completed",
                 else: "Swarm execution halted with diagnostics"
               ),
             completed_at: DateTime.utc_now() |> DateTime.truncate(:second),
             duration_ms: duration
           }) do
        {:ok, updated_root} ->
          broadcast(session_id, {:operation_completed, updated_root})

        _ ->
          :ok
      end
    end

    update_db_session_status(
      session_id,
      if(state.status == :completed, do: "completed", else: "idle")
    )

    broadcast(session_id, {:session_status_changed, "idle"})

    broadcast(
      session_id,
      {:goal_lifecycle_changed, %{session_id: session_id, status: state.status}}
    )

    {:ok, final_msg}
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp create_root_operation(session_id, user_prompt) do
    case Sessions.create_operation(%{
           session_id: session_id,
           agent_name: "SwarmOrchestrator",
           op_type: "swarm_root",
           title: "Swarm Goal: #{String.slice(user_prompt, 0, 60)}...",
           status: "running",
           progress: 0,
           started_at: DateTime.utc_now() |> DateTime.truncate(:second),
           params: %{prompt: user_prompt}
         }) do
      {:ok, op} ->
        broadcast(session_id, {:operation_started, op})
        {:ok, op}

      _ ->
        {:ok, %{id: Ecto.UUID.generate()}}
    end
  end

  defp broadcast_stage(
         %State{session_id: session_id, start_time_ms: start_time} = state,
         stage,
         progress,
         message
       ) do
    latency_ms = System.monotonic_time(:millisecond) - start_time
    pid_str = inspect(self())

    event =
      {:swarm_stage_changed,
       %{
         session_id: session_id,
         stage: stage,
         progress: progress,
         latency_ms: latency_ms,
         agent_pid: pid_str,
         message: message
       }}

    persist_run_stage(state, stage, progress, message)
    broadcast(session_id, event)
  end

  defp persist_run_stage(
         %State{
           run_id: run_id,
           run_lease_owner: owner,
           run_attempt: attempt,
           run_lease_generation: generation,
           run_lease_ms: lease_ms
         },
         stage,
         progress,
         message
       )
       when is_binary(run_id) and is_binary(owner) and is_integer(attempt) and
              is_integer(generation) do
    case Runs.record_progress(run_id, progress, message, "swarm.#{stage}",
           lease_owner: owner,
           run_attempt: attempt,
           lease_generation: generation,
           lease_ms: lease_ms
         ) do
      {:ok, _run} -> :ok
      {:error, reason} -> throw({:durable_run_fenced, reason})
    end
  end

  defp persist_run_stage(_state, _stage, _progress, _message), do: :ok

  defp update_db_session_status(session_id, status_str) do
    case Sessions.get_session(session_id) do
      nil -> :ok
      s -> Sessions.update_session(s, %{status: status_str})
    end
  rescue
    _ -> :ok
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

  defp broadcast(session_id, event) do
    PubSub.broadcast(IexCode.PubSub, "session:#{session_id}", event)
  rescue
    _ -> :ok
  end

  defp compute_error_signature(diagnostics) when is_map(diagnostics) do
    # Extract deterministic semantic fields: status, failures, compilation_errors
    status = Map.get(diagnostics, :status)
    failures = Map.get(diagnostics, :failures, [])
    compilation_errors = Map.get(diagnostics, :compilation_errors, [])

    if failures != [] or compilation_errors != [] do
      :erlang.phash2({status, failures, compilation_errors})
    else
      # If structured failures/compilation_errors are empty, fall back to normalized text
      raw = Map.get(diagnostics, :summary) || Map.get(diagnostics, :raw_output)

      clean_text =
        case raw do
          text when is_binary(text) ->
            Regex.replace(~r/Finished in [0-9.]+ seconds.*?\n/, text, "")

          other ->
            other
        end

      :erlang.phash2({status, clean_text})
    end
  end

  defp compute_error_signature(other) do
    :erlang.phash2(other)
  end
end
