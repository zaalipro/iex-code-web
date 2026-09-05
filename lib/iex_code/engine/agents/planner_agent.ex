defmodule IexCode.Engine.Agents.PlannerAgent do
  @moduledoc """
  Dedicated OTP GenServer subagent responsible for goal decomposition,
  architectural analysis, and task planning for Explorer, Coder, and Verifier.
  """
  use GenServer, restart: :transient
  require Logger
  alias IexCode.Engine.{AgentCancellation, AgentRegistry, AgentStateRetention, OperationManager}
  alias IexCode.Execution.ModelRoute
  alias IexCode.{Sessions, Settings, Tools, LLM}

  @outer_timeout 90_000
  @inner_timeout 60_000

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
          AgentRegistry.via_tuple(session_id, :planner)
      end

    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Decomposes a user goal into an actionable architecture and execution plan.
  Accepts a session_id string or direct PID.
  """
  def plan(target, prompt, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @outer_timeout)
    GenServer.call(resolve_target(target), {:plan, prompt, opts}, timeout)
  end

  @doc """
  Returns the current internal state of the PlannerAgent.
  """
  def get_state(target) do
    GenServer.call(resolve_target(target), :get_state)
  end

  defp resolve_target(pid) when is_pid(pid), do: pid

  defp resolve_target(session_id) when is_binary(session_id) do
    AgentRegistry.via_tuple(session_id, :planner)
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
        role: :planner,
        generation: opts[:generation]
      })
    end
  end

  @impl true
  def handle_call({:plan, prompt, opts}, _from, %State{} = state) do
    session_id = state.session_id
    project_root = opts[:project_root] || state.project_root
    parent_op_id = opts[:parent_op_id]

    session =
      state.session ||
        try do
          Sessions.get_session!(session_id)
        rescue
          _ -> nil
        end

    runtime_owner = Process.get(:iex_code_fleet_owner)

    plan_res =
      IexCode.Engine.FleetRuntime.run(runtime_owner, state.control_token, "planning", fn ->
        OperationManager.run_sync_operation(
          session_id,
          parent_op_id,
          "PlannerAgent",
          "subagent_plan",
          "Planner: Decomposing architecture & execution plan",
          %{prompt: prompt},
          fn progress ->
            progress.(15, "Analyzing user request and workspace architecture...")

            # Inspect top-level workspace structure and feed it into the prompt
            dir_result =
              if tool_allowed?("list_dir", Keyword.get(opts, :allowed_tools, :all)) do
                OperationManager.run_sync_operation(
                  session_id,
                  parent_op_id,
                  "PlannerAgent",
                  "list_dir",
                  "Planner: Inspecting workspace directory",
                  %{path: ""},
                  fn p ->
                    Tools.execute(
                      "list_dir",
                      %{"path" => "", "recursive" => false},
                      project_root,
                      p
                    )
                  end
                )
              else
                {:error, {:tool_not_allowed, "list_dir"}}
              end

            dir_summary =
              case dir_result do
                {:ok, listing} when is_binary(listing) -> listing
                {:ok, other} -> inspect(other)
                {:error, reason} -> "(workspace listing unavailable: #{format_reason(reason)})"
              end

            progress.(60, "Formulating task decomposition...")

            steer_directives = Keyword.get(opts, :steer_directives, [])

            system_prompt = """
            You are the Master Planner in an Elixir coding swarm.
            Analyze the user's goal, break it down into clear architectural steps for the Explorer, Coder, and Verifier agents.
            Keep the response clear, structured, and action-oriented.
            """

            base_content =
              "Goal: #{prompt}\nProject root: #{project_root}\n\nWorkspace structure:\n#{dir_summary}"

            messages = [
              %{role: "user", content: append_steer_directives(base_content, steer_directives)}
            ]

            base_llm_opts = [
              cancelled?: cancelled_fun(state),
              allowed_tools: Keyword.get(opts, :allowed_tools, :all)
            ]

            with {:ok, llm_opts} <-
                   durable_model_options(opts[:execution_policy], state.llm, base_llm_opts) do
              case state.llm.chat(messages, system_prompt, session, fn _c -> :ok end, llm_opts) do
                {:ok, %{text: plan_text} = response}
                when is_binary(plan_text) and byte_size(plan_text) > 0 ->
                  with :ok <-
                         persist_run_usage(Keyword.get(opts, :run_id), response, runtime_owner) do
                    progress.(100, "Plan ready")
                    {:ok, plan_text}
                  end

                {:error, :cancelled} ->
                  {:error, :cancelled}

                _ ->
                  fallback_plan =
                    """
                    1. Inspect workspace structure and relevant modules.
                    2. Implement required changes or functions.
                    3. Run tests and verify code compilation.
                    """
                    |> String.trim()

                  progress.(100, "Default plan created")
                  {:ok, fallback_plan}
              end
            end
          end,
          Keyword.get(opts, :inner_timeout, @inner_timeout)
        )
      end)

    case plan_res do
      {:ok, plan_text} ->
        {last_result, history} = AgentStateRetention.remember(state.history, plan_text)

        new_state = %State{
          state
          | status: :idle,
            last_result: last_result,
            history: history
        }

        {:reply, {:ok, plan_text}, new_state, :hibernate}

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
  def handle_call(:get_state, _from, %State{} = state) do
    {:reply, state, state, :hibernate}
  end

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)

  defp durable_model_options(nil, _llm, opts), do: {:ok, opts}

  defp durable_model_options(policy, llm, opts) when is_map(policy) do
    with {:ok, route} <- ModelRoute.resolve(policy, Settings.get_settings()) do
      if llm == LLM,
        do: {:ok, Keyword.put(opts, :resolved_route, route)},
        else: {:ok, opts}
    end
  end

  defp durable_model_options(_policy, _llm, _opts), do: {:error, :invalid_execution_policy}

  defp persist_run_usage(nil, _response, _state), do: :ok

  defp persist_run_usage(run_id, response, runtime_owner) do
    usage = Map.get(response, :usage) || Map.get(response, "usage")

    if is_map(usage) do
      result =
        if runtime_owner do
          IexCode.Engine.FleetRuntime.record_usage(runtime_owner, usage, "planner.llm")
        else
          IexCode.Runs.record_usage(run_id, usage, "planner.llm")
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

  defp tool_allowed?(_tool_name, :all), do: true
  defp tool_allowed?(_tool_name, nil), do: true

  defp tool_allowed?(tool_name, allowed_tools) when is_list(allowed_tools),
    do: tool_name in Enum.map(allowed_tools, &to_string/1)

  defp tool_allowed?(_tool_name, _allowed_tools), do: false

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
