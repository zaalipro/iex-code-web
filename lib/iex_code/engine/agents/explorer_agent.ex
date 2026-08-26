defmodule IexCode.Engine.Agents.ExplorerAgent do
  @moduledoc """
  Dedicated OTP GenServer subagent responsible for codebase traversal,
  AST symbol search, file discovery, and codebase context synthesis.
  """
  use GenServer, restart: :transient
  require Logger
  alias IexCode.Engine.{AgentRegistry, OperationManager}
  alias IexCode.Tools
  alias IexCode.Tools.ASTSearch

  @outer_timeout 90_000
  @inner_timeout 60_000

  @stopwords ~w(the and for with this that from into your you are have has will would should could
                implement create make code file files please using used when then them they what
                which there here about after before between during through under over need wants)

  defmodule State do
    defstruct [
      :session_id,
      :session,
      :project_root,
      :control_token,
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
          AgentRegistry.via_tuple(session_id, :explorer)
      end

    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Explores the codebase based on the user prompt and optional plan.
  """
  def explore(target, prompt, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @outer_timeout)
    GenServer.call(resolve_target(target), {:explore, prompt, opts}, timeout)
  end

  @doc """
  Searches AST symbols across the project workspace.
  """
  def search_ast(target, query_map, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 60_000)
    GenServer.call(resolve_target(target), {:search_ast, query_map, opts}, timeout)
  end

  @doc """
  Performs a regex or literal grep search across the project workspace.
  """
  def grep(target, query, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 60_000)
    GenServer.call(resolve_target(target), {:grep, query, opts}, timeout)
  end

  @doc """
  Executes a shell command in the context of the ExplorerAgent.
  """
  def run_command(target, command, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 60_000)
    GenServer.call(resolve_target(target), {:run_command, command, opts}, timeout)
  end

  @doc """
  Returns the current internal state of the ExplorerAgent.
  """
  def get_state(target) do
    GenServer.call(resolve_target(target), :get_state)
  end

  defp resolve_target(pid) when is_pid(pid), do: pid

  defp resolve_target(session_id) when is_binary(session_id) do
    AgentRegistry.via_tuple(session_id, :explorer)
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
      status: :idle
    }

    unless is_binary(opts[:run_id]) do
      set_cancelled?(session_id, false)
      subscribe_steering(session_id)
    end

    {:ok, state}
  end

  defp mark_fleet_owner(opts) do
    if is_binary(opts[:run_id]) and is_binary(opts[:agent_id]) do
      Process.put(:iex_code_fleet_owner, IexCode.Engine.FleetRuntime.owner(opts))
      Process.put(:iex_code_fleet_control_token, opts[:control_token])

      AgentRegistry.put_agent_metadata(opts[:run_id], opts[:agent_id], %{
        role: :explorer,
        generation: opts[:generation]
      })
    end
  end

  @impl true
  def handle_call({:explore, prompt, opts}, _from, %State{} = state) do
    session_id = state.session_id
    project_root = opts[:project_root] || state.project_root
    parent_op_id = opts[:parent_op_id]
    allowed_tools = Keyword.get(opts, :allowed_tools, :all)

    runtime_owner = Process.get(:iex_code_fleet_owner)

    explore_res =
      IexCode.Engine.FleetRuntime.run(runtime_owner, state.control_token, "exploring", fn ->
        OperationManager.run_sync_operation(
          session_id,
          parent_op_id,
          "ExplorerAgent",
          "grep_search",
          "Explorer: Scanning codebase for relevant files & symbols",
          %{prompt: prompt},
          fn progress ->
            if cancelled_fun(state).() do
              {:error, :cancelled}
            else
              progress.(20, "Searching project files...")

              # Derive the grep query from the prompt (plus any steering directives)
              search_text =
                Enum.join([prompt | Keyword.get(opts, :steer_directives, [])], "\n")

              query = derive_search_query(search_text)

              # Run grep operation for the derived query
              grep_res =
                if tool_allowed?("grep_search", allowed_tools) do
                  OperationManager.run_sync_operation(
                    session_id,
                    parent_op_id,
                    "ExplorerAgent",
                    "grep_search",
                    "Explorer: Grepping for modules and definitions",
                    %{query: query},
                    fn p ->
                      Tools.execute("grep_search", %{"query" => query}, project_root, p)
                    end,
                    Keyword.get(opts, :inner_timeout, @inner_timeout)
                  )
                else
                  {:error, {:tool_not_allowed, "grep_search"}}
                end

              if cancelled_fun(state).() do
                {:error, :cancelled}
              else
                progress.(60, "Scanning AST symbols...")

                # Run AST search for key symbols if specified
                ast_symbols =
                  if tool_allowed?("ast_search", allowed_tools) do
                    case ASTSearch.search(project_root, %{type: "module"}) do
                      {:ok, syms} -> syms
                      _ -> []
                    end
                  else
                    []
                  end

                progress.(80, "Synthesizing codebase context...")

                context_summary =
                  cond do
                    match?(
                      {:ok, output} when is_binary(output) and byte_size(output) > 0,
                      grep_res
                    ) ->
                      {:ok, output} = grep_res
                      "Found key modules in workspace:\n#{String.slice(output, 0, 1500)}"

                    ast_symbols != [] ->
                      sym_list =
                        Enum.map_join(
                          Enum.take(ast_symbols, 10),
                          "\n",
                          &"- #{&1.name} (#{Path.relative_to(&1.file, project_root)}:#{&1.line})"
                        )

                      "Discovered AST modules:\n#{sym_list}"

                    true ->
                      "Workspace exploration complete. Ready for implementation."
                  end

                progress.(100, "Exploration complete")
                {:ok, context_summary}
              end
            end
          end,
          Keyword.get(opts, :inner_timeout, @inner_timeout)
        )
      end)

    case explore_res do
      {:ok, summary} ->
        new_state = %State{
          state
          | status: :idle,
            last_result: summary,
            history: [summary | state.history]
        }

        {:reply, {:ok, summary}, new_state}

      {:error, reason} ->
        new_state = %State{state | status: :idle, last_result: {:error, reason}}
        {:reply, {:error, reason}, new_state}
    end
  end

  @impl true
  def handle_call({:search_ast, query_map, opts}, _from, %State{} = state) do
    project_root = opts[:project_root] || state.project_root
    res = ASTSearch.search(project_root, query_map)
    {:reply, res, state}
  end

  @impl true
  def handle_call({:grep, query, opts}, _from, %State{} = state) do
    project_root = opts[:project_root] || state.project_root
    res = Tools.execute("grep_search", %{"query" => query}, project_root, fn _, _ -> :ok end)
    {:reply, res, state}
  end

  @impl true
  def handle_call({:run_command, command, opts}, _from, %State{} = state) do
    project_root = opts[:project_root] || state.project_root
    timeout = Keyword.get(opts, :timeout_ms, 30_000)

    args = %{
      "command" => command,
      "project_id" => trusted_project_id(state),
      "run_id" => opts[:run_id],
      "session_id" => state.session_id,
      "agent_name" => "ExplorerAgent",
      "op_id" => opts[:op_id] || state.current_op_id,
      "timeout_ms" => timeout
    }

    res =
      with_workspace_delegation(opts[:workspace_lock_delegation], fn ->
        Tools.execute("run_command", args, project_root, fn _, _ -> :ok end)
      end)

    {:reply, res, state}
  end

  @impl true
  def handle_call(:get_state, _from, %State{} = state) do
    {:reply, state, state}
  end

  defp trusted_project_id(state) do
    (state.session && state.session.project_id) ||
      case IexCode.Sessions.get_session(state.session_id) do
        %{project_id: project_id} -> project_id
        _ -> nil
      end
  end

  defp with_workspace_delegation(nil, fun), do: fun.()

  defp with_workspace_delegation(delegation, fun) do
    IexCode.WorkspaceLocks.with_delegation(delegation, fun)
  end

  # Search derivation

  defp derive_search_query(text) do
    words =
      text
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9_\-]+/, " ")
      |> String.split(" ", trim: true)
      |> Enum.reject(&(String.length(&1) < 4 or &1 in @stopwords))
      |> Enum.uniq()
      |> Enum.take(3)

    case words do
      [] -> "defmodule"
      words -> Enum.map_join(words, "|", &Regex.escape/1)
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

  defp set_cancelled?(session_id, value) do
    :persistent_term.put({__MODULE__, :cancelled?, session_id}, value)
  end

  defp cancelled_fun(%State{control_token: nil, session_id: session_id}) do
    fn -> :persistent_term.get({__MODULE__, :cancelled?, session_id}, false) end
  end

  defp cancelled_fun(%State{control_token: token}) do
    fn -> IexCode.Engine.FleetControlToken.checkpoint(token) == :cancelled end
  end

  @impl true
  def handle_info({:cancel, session_id, _opts}, state) do
    set_cancelled?(session_id, true)
    {:noreply, state}
  end

  @impl true
  def handle_info({:pause, session_id}, state) do
    set_cancelled?(session_id, true)
    {:noreply, state}
  end

  @impl true
  def handle_info({:resume, session_id}, state) do
    set_cancelled?(session_id, false)
    {:noreply, state}
  end

  @impl true
  def handle_info({ref, _result}, state) when is_reference(ref) do
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info({:operation_task_done, _op_id, _result}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end
end
