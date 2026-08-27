defmodule IexCode.Engine.Agents.CoderAgent do
  @moduledoc """
  Dedicated OTP GenServer subagent responsible for code implementation,
  patch formulation, LLM prompt synthesis, and multi-file atomic edits.
  """
  use GenServer, restart: :transient
  require Logger
  alias IexCode.Engine.{AgentCancellation, AgentRegistry, AgentStateRetention, OperationManager}
  alias IexCode.Execution.ModelRoute
  alias IexCode.{Sessions, Settings, Tools, LLM}
  alias IexCode.Tools.AutoFix

  @outer_timeout 90_000
  @inner_timeout 60_000
  @legacy_max_tool_iterations 5
  @max_configured_tool_iterations 20

  defmodule State do
    defstruct [
      :session_id,
      :session,
      :project_root,
      :control_token,
      :cancel_token,
      :llm,
      status: :idle,
      current_op_id: nil,
      last_result: nil,
      applied_patches: [],
      history: []
    ]
  end

  # Client API

  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)

    name =
      case {opts[:run_id], opts[:agent_id]} do
        {run_id, agent_id} when is_binary(run_id) and is_binary(agent_id) ->
          AgentRegistry.via_agent(run_id, agent_id)

        _ ->
          AgentRegistry.via_tuple(session_id, :coder)
      end

    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Generates and applies code modifications for a given prompt and context.
  """
  def code(target, prompt, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @outer_timeout)
    GenServer.call(resolve_target(target), {:code, prompt, opts}, timeout)
  end

  @doc """
  Applies atomic patches via MultiPatch engine.
  """
  def apply_patches(target, patches, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 60_000)
    GenServer.call(resolve_target(target), {:apply_patches, patches, opts}, timeout)
  end

  @doc """
  Returns the current internal state of the CoderAgent.
  """
  def get_state(target) do
    GenServer.call(resolve_target(target), :get_state)
  end

  defp resolve_target(pid) when is_pid(pid), do: pid

  defp resolve_target(session_id) when is_binary(session_id) do
    AgentRegistry.via_tuple(session_id, :coder)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    mark_fleet_owner(opts)
    session_id = Keyword.fetch!(opts, :session_id)
    session = opts[:session]

    project_root =
      opts[:project_root] || (session && session.project && session.project.root_path) ||
        File.cwd!()

    state = %State{
      session_id: session_id,
      session: session,
      project_root: project_root,
      control_token: opts[:control_token],
      cancel_token: if(is_binary(opts[:run_id]), do: nil, else: AgentCancellation.new()),
      llm: Keyword.get(opts, :llm, LLM),
      status: :idle
    }

    unless is_binary(opts[:run_id]) do
      AgentCancellation.erase_legacy(__MODULE__, session_id)
      subscribe_steering(session_id)
    end

    {:ok, state}
  end

  defp mark_fleet_owner(opts) do
    if is_binary(opts[:run_id]) and is_binary(opts[:agent_id]) do
      Process.put(:iex_code_fleet_owner, IexCode.Engine.FleetRuntime.owner(opts))
      Process.put(:iex_code_fleet_control_token, opts[:control_token])

      AgentRegistry.put_agent_metadata(opts[:run_id], opts[:agent_id], %{
        role: :coder,
        generation: opts[:generation]
      })
    end
  end

  @impl true
  def handle_call({:code, prompt, opts}, _from, %State{} = state) do
    session_id = state.session_id
    opts = Keyword.put_new(opts, :session_id, session_id)
    project_root = opts[:project_root] || state.project_root
    parent_op_id = opts[:parent_op_id]

    session =
      opts[:session] || state.session ||
        try do
          Sessions.get_session!(session_id)
        rescue
          _ -> nil
        end

    plan = opts[:plan] || ""
    explorer_context = opts[:context] || ""
    diagnostics = opts[:diagnostics]

    runtime_owner = Process.get(:iex_code_fleet_owner)

    code_res =
      IexCode.Engine.FleetRuntime.run(runtime_owner, state.control_token, "coding", fn ->
        OperationManager.run_sync_operation(
          session_id,
          parent_op_id,
          "CoderAgent",
          "llm_stream",
          "Coder: Generating implementation and code patches",
          %{prompt: prompt},
          fn progress ->
            progress.(15, "Generating code solution with LLM...")

            steer_directives = Keyword.get(opts, :steer_directives, [])

            system_prompt = """
            You are the Coder Agent in an Elixir coding swarm.
            Based on the plan and exploration context, implement the required code.
            If code edits or new files are needed, describe the files and changes clearly.
            """

            base_content =
              if diagnostics do
                diag_str = AutoFix.format_diagnostics(diagnostics)

                """
                ### ⚠️ Self-Correction Feedback
                #{diag_str}

                Task: #{prompt}
                """
              else
                "Plan:\n#{plan}\n\nContext:\n#{explorer_context}\n\nTask:\n#{prompt}"
              end

            messages = [
              %{role: "user", content: append_steer_directives(base_content, steer_directives)}
            ]

            with :ok <- apply_explicit_patches(opts, project_root, progress),
                 {:ok, max_tool_iterations} <-
                   max_tool_iterations(opts[:execution_policy]),
                 {:ok, code_text} <-
                   run_tool_loop(
                     session_id,
                     messages,
                     system_prompt,
                     session,
                     project_root,
                     parent_op_id,
                     opts[:run_id],
                     trusted_project_id(opts, state),
                     opts[:workspace_lock_delegation],
                     Keyword.get(opts, :allowed_tools, :all),
                     cancelled_fun(state),
                     state.llm,
                     opts[:execution_policy],
                     max_tool_iterations,
                     runtime_owner,
                     progress,
                     0
                   ) do
              progress.(100, "Implementation complete")
              {:ok, code_text}
            else
              {:error, reason} = err ->
                progress.(100, "Implementation failed: #{format_reason(reason)}")
                err
            end
          end,
          Keyword.get(opts, :inner_timeout, @inner_timeout)
        )
      end)

    case code_res do
      {:ok, code_result} ->
        {last_result, history} = AgentStateRetention.remember(state.history, code_result)

        new_state = %State{
          state
          | status: :idle,
            last_result: last_result,
            history: history
        }

        {:reply, {:ok, code_result}, new_state, :hibernate}

      {:error, reason} ->
        new_state = %State{
          state
          | status: :idle,
            last_result: AgentStateRetention.retain({:error, reason})
        }

        {:reply, {:error, reason}, new_state, :hibernate}
    end
  end

  @impl true
  def handle_call({:apply_patches, patches, opts}, _from, %State{} = state) do
    opts =
      opts
      |> Keyword.put_new(:session_id, state.session_id)
      |> Keyword.put(:project_id, trusted_project_id(opts, state))

    project_root = opts[:project_root] || state.project_root

    res =
      with_workspace_delegation(opts[:workspace_lock_delegation], fn ->
        Tools.multi_patch(patches, project_root, opts)
      end)

    {:reply, res, state, :hibernate}
  end

  @impl true
  def handle_call(:get_state, _from, %State{} = state) do
    {:reply, state, state, :hibernate}
  end

  # Tool loop helpers

  defp apply_explicit_patches(opts, project_root, progress) do
    patches = opts[:patches]

    if is_list(patches) and patches != [] do
      progress.(30, "Applying #{length(patches)} atomic patches...")

      case with_workspace_delegation(opts[:workspace_lock_delegation], fn ->
             Tools.multi_patch(patches, project_root, opts)
           end) do
        {:ok, _summary} -> :ok
        {:error, reason} -> {:error, {:patch_application_failed, reason}}
      end
    else
      :ok
    end
  end

  defp run_tool_loop(
         session_id,
         messages,
         system_prompt,
         session,
         project_root,
         parent_op_id,
         run_id,
         project_id,
         workspace_lock_delegation,
         allowed_tools,
         cancelled?,
         llm,
         execution_policy,
         max_tool_iterations,
         usage_context,
         progress,
         iteration
       ) do
    if iteration >= max_tool_iterations do
      {:error, {:tool_iteration_limit_reached, max_tool_iterations}}
    else
      progress.(
        min(90, 40 + iteration * 10),
        "LLM iteration #{iteration + 1}/#{max_tool_iterations}..."
      )

      base_llm_opts = [cancelled?: cancelled?, allowed_tools: allowed_tools]

      with {:ok, llm_opts} <- durable_model_options(execution_policy, llm, base_llm_opts) do
        case llm.chat(messages, system_prompt, session, fn _c -> :ok end, llm_opts) do
          {:ok, %{text: text, tool_calls: tool_calls} = response} when tool_calls != [] ->
            with :ok <- persist_run_usage(run_id, response, usage_context) do
              progress.(60, "Executing #{length(tool_calls)} tool call(s)...")

              tool_messages =
                Enum.map(
                  tool_calls,
                  &execute_tool_call(
                    &1,
                    session_id,
                    project_root,
                    parent_op_id,
                    run_id,
                    project_id,
                    workspace_lock_delegation,
                    allowed_tools
                  )
                )

              run_tool_loop(
                session_id,
                messages ++ assistant_messages(text) ++ tool_messages,
                system_prompt,
                session,
                project_root,
                parent_op_id,
                run_id,
                project_id,
                workspace_lock_delegation,
                allowed_tools,
                cancelled?,
                llm,
                execution_policy,
                max_tool_iterations,
                usage_context,
                progress,
                iteration + 1
              )
            end

          {:ok, %{text: text} = response} ->
            with :ok <- persist_run_usage(run_id, response, usage_context), do: {:ok, text || ""}

          {:ok, other} ->
            {:error, {:unexpected_llm_response, other}}

          {:error, reason} ->
            {:error, reason}
        end
      end
    end
  end

  defp durable_model_options(nil, _llm, opts), do: {:ok, opts}

  defp durable_model_options(policy, llm, opts) when is_map(policy) do
    with {:ok, route} <- ModelRoute.resolve(policy, Settings.get_settings()) do
      if llm == LLM,
        do: {:ok, Keyword.put(opts, :resolved_route, route)},
        else: {:ok, opts}
    end
  end

  defp durable_model_options(_policy, _llm, _opts), do: {:error, :invalid_execution_policy}

  # Policies are normalized and snapshotted before a durable run is queued. Read
  # the bound once per coder invocation so a Settings edit cannot alter an
  # in-flight swarm or one of its later diagnostic-repair invocations. Legacy
  # callers and policies created before this setting existed keep the original
  # five-turn behavior.
  defp max_tool_iterations(nil), do: {:ok, @legacy_max_tool_iterations}

  defp max_tool_iterations(policy) when is_map(policy) do
    case Map.get(policy, "agent_max_turns") || Map.get(policy, :agent_max_turns) do
      nil ->
        {:ok, @legacy_max_tool_iterations}

      turns when is_integer(turns) and turns in 1..@max_configured_tool_iterations ->
        {:ok, turns}

      _invalid ->
        {:error, :invalid_agent_max_turns}
    end
  end

  defp max_tool_iterations(_policy), do: {:error, :invalid_execution_policy}

  defp execute_tool_call(
         tc,
         session_id,
         project_root,
         parent_op_id,
         run_id,
         project_id,
         workspace_lock_delegation,
         allowed_tools
       ) do
    args =
      if is_map(tc.args) do
        Map.merge(
          tc.args,
          %{
            "session_id" => session_id,
            "run_id" => run_id,
            "project_id" => project_id,
            "agent_name" => "CoderAgent",
            "op_id" => parent_op_id
          }
        )
      else
        tc.args
      end

    res =
      if tool_allowed?(tc.name, allowed_tools) do
        OperationManager.run_sync_operation(
          session_id,
          parent_op_id,
          "CoderAgent",
          tc.name,
          "Coder: Executing #{tc.name}",
          args,
          fn p ->
            with_workspace_delegation(workspace_lock_delegation, fn ->
              Tools.execute(tc.name, args, project_root, p)
            end)
          end
        )
      else
        {:error, {:tool_not_allowed, tc.name}}
      end

    content =
      case res do
        {:ok, output} -> format_tool_output(output)
        {:error, reason} -> "ERROR: #{format_reason(reason)}"
      end

    %{role: "tool", content: content, tool_call_id: tc.id}
  end

  defp trusted_project_id(_opts, state) do
    (state.session && state.session.project_id) ||
      case Sessions.get_session(state.session_id) do
        %{project_id: project_id} -> project_id
        _ -> nil
      end
  end

  defp with_workspace_delegation(nil, fun), do: fun.()

  defp with_workspace_delegation(delegation, fun) do
    IexCode.WorkspaceLocks.with_delegation(delegation, fun)
  end

  defp assistant_messages(text) when text in [nil, ""], do: []

  defp assistant_messages(text) when is_binary(text),
    do: [%{role: "assistant", content: text}]

  defp format_tool_output(output) when is_binary(output) do
    if byte_size(output) > 4000 do
      String.slice(output, 0, 4000) <> "\n...(truncated)"
    else
      output
    end
  end

  defp format_tool_output(other), do: inspect(other)

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)

  defp tool_allowed?(_tool_name, :all), do: true
  defp tool_allowed?(_tool_name, nil), do: true

  defp tool_allowed?(tool_name, allowed_tools) when is_list(allowed_tools),
    do: to_string(tool_name) in Enum.map(allowed_tools, &to_string/1)

  defp tool_allowed?(_tool_name, _allowed_tools), do: false

  defp persist_run_usage(nil, _response, _state), do: :ok

  defp persist_run_usage(run_id, response, runtime_owner) do
    usage = Map.get(response, :usage) || Map.get(response, "usage")

    if is_map(usage) do
      result =
        if runtime_owner do
          IexCode.Engine.FleetRuntime.record_usage(runtime_owner, usage, "coder.llm")
        else
          IexCode.Runs.record_usage(run_id, usage, "coder.llm")
        end

      case result do
        :ok -> :ok
        {:ok, _run} -> :ok
        {:error, {:token_budget_exhausted, _run}} -> {:error, :token_budget_exhausted}
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

  # Steering / cancellation helpers

  defp subscribe_steering(session_id) do
    Phoenix.PubSub.subscribe(IexCode.PubSub, "session:#{session_id}:steer")
  end

  defp cancelled_fun(%State{control_token: nil, cancel_token: token}) do
    fn -> AgentCancellation.cancelled?(token) end
  end

  defp cancelled_fun(%State{control_token: token}) do
    fn -> IexCode.Engine.FleetControlToken.checkpoint(token) == :cancelled end
  end

  defp append_steer_directives(content, []), do: content

  defp append_steer_directives(content, directives) when is_list(directives) do
    content <>
      "\n\n### Steering Directives (highest priority, apply to this step)\n" <>
      Enum.map_join(directives, "\n", &"- #{&1}")
  end

  @impl true
  def handle_info({:cancel, session_id, _opts}, %{session_id: session_id} = state) do
    AgentCancellation.cancel(state.cancel_token)
    {:noreply, state, :hibernate}
  end

  @impl true
  def handle_info({:pause, session_id}, %{session_id: session_id} = state) do
    AgentCancellation.cancel(state.cancel_token)
    {:noreply, state, :hibernate}
  end

  @impl true
  def handle_info({:resume, session_id}, %{session_id: session_id} = state) do
    AgentCancellation.resume(state.cancel_token)
    {:noreply, state, :hibernate}
  end

  @impl true
  def handle_info({ref, _result}, state) when is_reference(ref) do
    {:noreply, state, :hibernate}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    {:noreply, state, :hibernate}
  end

  @impl true
  def handle_info({:operation_task_done, _op_id, _result}, state) do
    {:noreply, state, :hibernate}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state, :hibernate}
  end
end
