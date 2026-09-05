defmodule IexCode.Engine.AgentsTest do
  use IexCode.DataCase, async: false
  alias IexCode.{Projects, Sessions, Settings}
  alias IexCode.Engine.{AgentRegistry, AgentSupervisor}
  alias IexCode.Engine.Agents.{PlannerAgent, ExplorerAgent, CoderAgent, VerifierAgent}
  alias IexCode.E2E.MockLLMServer

  setup do
    {:ok, project} = Projects.create_project(%{name: "Agents Test Proj", root_path: File.cwd!()})

    {:ok, session} =
      Sessions.create_session(%{project_id: project.id, title: "Agents Test Session"})

    %{session: session, project: project}
  end

  describe "AgentRegistry and AgentSupervisor" do
    test "AgentRegistry resolves via_tuples and normalized types", %{session: session} do
      session_id = session.id

      assert {:via, Registry, {AgentRegistry, {^session_id, :planner}}} =
               AgentRegistry.via_tuple(session.id, :planner)

      assert {:via, Registry, {AgentRegistry, {^session_id, :explorer}}} =
               AgentRegistry.via_tuple(session.id, "explorer")

      assert {:via, Registry, {AgentRegistry, {^session_id, :coder}}} =
               AgentRegistry.via_tuple(session.id, "CoderAgent")

      assert {:via, Registry, {AgentRegistry, {^session_id, :verifier}}} =
               AgentRegistry.via_tuple(session.id, "VerifierAgent")
    end

    test "AgentSupervisor starts, finds, and terminates all 4 subagents", %{session: session} do
      # 1. Start subagents
      assert {:ok, planner_pid} = AgentSupervisor.start_agent(session.id, :planner)
      assert {:ok, explorer_pid} = AgentSupervisor.start_agent(session.id, :explorer)
      assert {:ok, coder_pid} = AgentSupervisor.start_agent(session.id, :coder)
      assert {:ok, verifier_pid} = AgentSupervisor.start_agent(session.id, :verifier)

      assert is_pid(planner_pid) and Process.alive?(planner_pid)
      assert is_pid(explorer_pid) and Process.alive?(explorer_pid)
      assert is_pid(coder_pid) and Process.alive?(coder_pid)
      assert is_pid(verifier_pid) and Process.alive?(verifier_pid)

      # 2. Idempotent start returns existing pid
      assert {:ok, ^planner_pid} = AgentSupervisor.start_agent(session.id, :planner)

      # 3. Lookup via registry & supervisor
      assert AgentRegistry.whereis(session.id, :planner) == planner_pid
      assert AgentSupervisor.find_agent(session.id, :explorer) == explorer_pid
      assert length(AgentRegistry.list_agents(session.id)) == 4

      # 4. Stop single agent
      assert :ok = AgentSupervisor.stop_agent(session.id, :planner)
      refute Process.alive?(planner_pid)
      assert AgentRegistry.whereis(session.id, :planner) == nil

      # 5. Stop all agents
      assert :ok = AgentSupervisor.stop_all_agents(session.id)
      assert AgentRegistry.list_agents(session.id) == []
    end

    test "cancel_session_activity stops agents and releases an agent-owned terminal", %{
      session: session,
      project: project
    } do
      assert {:ok, planner_pid} =
               AgentSupervisor.start_agent(session.id, :planner, project_root: project.root_path)

      assert {:ok, _terminal_pid} =
               IexCode.Tools.TerminalServer.ensure_started(session.id,
                 workspace_path: project.root_path
               )

      on_exit(fn -> IexCode.Tools.TerminalServer.kill(session.id) end)

      assert :ok =
               IexCode.Tools.TerminalSession.set_occupant(
                 session.id,
                 {:agent, "PlannerAgent", "cancel-test"}
               )

      ref = Process.monitor(planner_pid)
      assert :ok = AgentSupervisor.cancel_session_activity(session.id)
      assert_receive {:DOWN, ^ref, :process, ^planner_pid, _reason}
      assert AgentRegistry.list_agents(session.id) == []
      assert {:ok, %{occupant: :user}} = IexCode.Tools.TerminalServer.get_state(session.id)
    end

    test "cancel_session_activity does not restart an idle user terminal", %{
      session: session,
      project: project
    } do
      assert {:ok, terminal_pid} =
               IexCode.Tools.TerminalServer.ensure_started(session.id,
                 workspace_path: project.root_path
               )

      on_exit(fn -> IexCode.Tools.TerminalServer.kill(session.id) end)

      assert :ok = AgentSupervisor.cancel_session_activity(session.id)
      assert IexCode.Tools.TerminalServer.whereis(session.id) == terminal_pid
      assert Process.alive?(terminal_pid)
    end
  end

  describe "PlannerAgent GenServer" do
    test "propagates provider cancellation instead of reporting a default plan", %{
      session: session,
      project: project
    } do
      {:ok, pid} =
        AgentSupervisor.start_agent(session.id, :planner,
          project_root: project.root_path,
          llm: IexCode.CancelledLLMStub
        )

      Ecto.Adapters.SQL.Sandbox.allow(IexCode.Repo, self(), pid)

      assert {:error, :cancelled} = PlannerAgent.plan(pid, "Cancellation must stop planning")
      assert PlannerAgent.get_state(pid).last_result == {:error, :cancelled}

      AgentSupervisor.stop_agent(session.id, :planner)
    end

    test "plans goal decomposition and tracks state", %{session: session, project: project} do
      {:ok, pid} =
        AgentSupervisor.start_agent(session.id, :planner, project_root: project.root_path)

      Ecto.Adapters.SQL.Sandbox.allow(IexCode.Repo, self(), pid)

      assert {:ok, plan} = PlannerAgent.plan(session.id, "Design a key-value store module")
      assert is_binary(plan) and byte_size(plan) > 0

      state = PlannerAgent.get_state(session.id)
      assert state.status == :idle
      assert state.last_result == plan
      assert plan in state.history

      # Clean up
      AgentSupervisor.stop_agent(session.id, :planner)
    end

    test "durable swarm planner rejects endpoint drift before its model effect", %{
      session: session,
      project: project
    } do
      assert {:ok, original} =
               Settings.update_settings(%{
                 openai_api_key: "route-test-key",
                 openai_base_url: "https://original-route.example/v1"
               })

      policy = Settings.execution_policy(original, session)

      assert {:ok, _changed} =
               Settings.update_settings(%{
                 openai_base_url: "https://changed-route.example/v1"
               })

      {:ok, pid} =
        AgentSupervisor.start_agent(session.id, :planner, project_root: project.root_path)

      Ecto.Adapters.SQL.Sandbox.allow(IexCode.Repo, self(), pid)

      assert {:error, :model_route_configuration_changed} =
               PlannerAgent.plan(session.id, "Do not dispatch this prompt",
                 run_id: Ecto.UUID.generate(),
                 execution_policy: policy
               )

      AgentSupervisor.stop_agent(session.id, :planner)
    end

    test "large planner results are returned in full but retained as bounded summaries", %{
      session: session,
      project: project
    } do
      previous = Application.get_env(:iex_code, :agent_state_retention)

      Application.put_env(:iex_code, :agent_state_retention,
        inline_bytes: 128,
        preview_bytes: 32,
        history_items: 2,
        history_bytes: 1_024
      )

      on_exit(fn ->
        if is_nil(previous) do
          Application.delete_env(:iex_code, :agent_state_retention)
        else
          Application.put_env(:iex_code, :agent_state_retention, previous)
        end
      end)

      {:ok, pid} =
        AgentSupervisor.start_agent(session.id, :planner,
          project_root: project.root_path,
          llm: IexCode.AgentRetentionLLMStub
        )

      Ecto.Adapters.SQL.Sandbox.allow(IexCode.Repo, self(), pid)

      assert {:ok, result} = PlannerAgent.plan(pid, "Return a deliberately large plan")
      assert byte_size(result) > 20_000

      state = PlannerAgent.get_state(pid)
      assert IexCode.Engine.AgentStateRetention.summary?(state.last_result)
      assert [summary] = state.history
      assert summary == state.last_result
      assert :erlang.external_size(state.history) < 1_024

      AgentSupervisor.stop_agent(session.id, :planner)
    end
  end

  describe "ExplorerAgent GenServer" do
    test "explores codebase and searches AST symbols", %{session: session, project: project} do
      {:ok, pid} =
        AgentSupervisor.start_agent(session.id, :explorer, project_root: project.root_path)

      Ecto.Adapters.SQL.Sandbox.allow(IexCode.Repo, self(), pid)

      assert {:ok, summary} = ExplorerAgent.explore(session.id, "Find all modules in workspace")
      assert is_binary(summary)

      # AST search
      assert {:ok, syms} = ExplorerAgent.search_ast(session.id, %{type: "module"})
      assert is_list(syms)

      # Grep search
      assert {:ok, grep_res} = ExplorerAgent.grep(session.id, "defmodule")
      assert is_binary(grep_res)

      state = ExplorerAgent.get_state(session.id)
      assert state.status == :idle

      AgentSupervisor.stop_agent(session.id, :explorer)
    end
  end

  describe "CoderAgent GenServer" do
    test "durable policy snapshots bound every coder tool/model loop", %{
      session: session,
      project: project
    } do
      tool_response =
        {:ok,
         %{
           text: "",
           tool_calls: [%{id: "call-1", name: "read_file", args: %{}}]
         }}

      completion = {:ok, %{text: "complete", tool_calls: []}}

      assert {:ok, low_settings} = Settings.update_settings(%{agent_max_turns: 2})
      low_policy = Settings.execution_policy(low_settings, session)

      # The queued run keeps its snapshot even if the global default changes
      # before its coder (or a later repair coder) is invoked.
      assert {:ok, _current_settings} = Settings.update_settings(%{agent_max_turns: 20})

      start_supervised!({IexCode.CoderAgentLoopLLMStub, List.duplicate(tool_response, 20)})

      {:ok, pid} =
        AgentSupervisor.start_agent(session.id, :coder,
          project_root: project.root_path,
          llm: IexCode.CoderAgentLoopLLMStub
        )

      Ecto.Adapters.SQL.Sandbox.allow(IexCode.Repo, self(), pid)

      assert {:error, {:tool_iteration_limit_reached, 2}} =
               CoderAgent.code(session.id, "bounded durable coding",
                 execution_policy: low_policy,
                 allowed_tools: []
               )

      assert IexCode.CoderAgentLoopLLMStub.calls() == 2
      AgentSupervisor.stop_agent(session.id, :coder)

      stop_supervised!(IexCode.CoderAgentLoopLLMStub)

      start_supervised!({IexCode.CoderAgentLoopLLMStub, List.duplicate(tool_response, 20)})

      {:ok, pid} =
        AgentSupervisor.start_agent(session.id, :coder,
          project_root: project.root_path,
          llm: IexCode.CoderAgentLoopLLMStub
        )

      Ecto.Adapters.SQL.Sandbox.allow(IexCode.Repo, self(), pid)

      assert {:error, {:tool_iteration_limit_reached, 2}} =
               CoderAgent.code(session.id, "bounded diagnostic repair",
                 execution_policy: low_policy,
                 diagnostics: %{compile: "still failing"},
                 allowed_tools: []
               )

      assert IexCode.CoderAgentLoopLLMStub.calls() == 2
      AgentSupervisor.stop_agent(session.id, :coder)

      stop_supervised!(IexCode.CoderAgentLoopLLMStub)

      start_supervised!(
        {IexCode.CoderAgentLoopLLMStub, List.duplicate(tool_response, 6) ++ [completion]}
      )

      assert {:ok, high_settings} = Settings.update_settings(%{agent_max_turns: 7})
      high_policy = Settings.execution_policy(high_settings, session)

      {:ok, pid} =
        AgentSupervisor.start_agent(session.id, :coder,
          project_root: project.root_path,
          llm: IexCode.CoderAgentLoopLLMStub
        )

      Ecto.Adapters.SQL.Sandbox.allow(IexCode.Repo, self(), pid)

      assert {:ok, "complete"} =
               CoderAgent.code(session.id, "bounded durable coding",
                 execution_policy: high_policy,
                 allowed_tools: []
               )

      assert IexCode.CoderAgentLoopLLMStub.calls() == 7
      AgentSupervisor.stop_agent(session.id, :coder)
    end

    test "legacy coder invocations retain the five-turn ceiling", %{
      session: session,
      project: project
    } do
      tool_response =
        {:ok,
         %{
           text: "",
           tool_calls: [%{id: "legacy-call", name: "read_file", args: %{}}]
         }}

      start_supervised!(
        {IexCode.CoderAgentLoopLLMStub,
         List.duplicate(tool_response, 5) ++ [{:ok, %{text: "too late", tool_calls: []}}]}
      )

      {:ok, pid} =
        AgentSupervisor.start_agent(session.id, :coder,
          project_root: project.root_path,
          llm: IexCode.CoderAgentLoopLLMStub
        )

      Ecto.Adapters.SQL.Sandbox.allow(IexCode.Repo, self(), pid)

      assert {:error, {:tool_iteration_limit_reached, 5}} =
               CoderAgent.code(session.id, "legacy coding", allowed_tools: [])

      assert IexCode.CoderAgentLoopLLMStub.calls() == 5
      AgentSupervisor.stop_agent(session.id, :coder)
    end

    test "in-progress durable swarm coder rejects endpoint drift before a model turn", %{
      session: session,
      project: project
    } do
      assert {:ok, original} =
               Settings.update_settings(%{
                 openai_api_key: "route-test-key",
                 openai_base_url: "https://original-coder-route.example/v1"
               })

      policy = Settings.execution_policy(original, session)

      {:ok, pid} =
        AgentSupervisor.start_agent(session.id, :coder, project_root: project.root_path)

      Ecto.Adapters.SQL.Sandbox.allow(IexCode.Repo, self(), pid)

      assert {:ok, _changed} =
               Settings.update_settings(%{
                 openai_base_url: "https://changed-coder-route.example/v1"
               })

      assert {:error, :model_route_configuration_changed} =
               CoderAgent.code(session.id, "Do not dispatch this prompt",
                 run_id: Ecto.UUID.generate(),
                 execution_policy: policy
               )

      AgentSupervisor.stop_agent(session.id, :coder)
    end

    @tag :tmp_dir
    test "generates code and applies atomic patches", %{tmp_dir: tmp_dir} do
      {:ok, project} =
        Projects.create_project(%{name: "Coder temp workspace", root_path: tmp_dir})

      {:ok, session} =
        Sessions.create_session(%{project_id: project.id, title: "Coder temp session"})

      # No real LLM credentials in the test environment: point the LLM at a local mock server
      {:ok, mock_pid, mock_info} = MockLLMServer.start(scenario: :standard_completion)

      on_exit(fn ->
        MockLLMServer.stop(mock_pid)
      end)

      {:ok, _} =
        Settings.update_settings(%{
          openai_base_url: "#{mock_info.url}/v1",
          anthropic_base_url: "#{mock_info.url}/v1",
          openai_api_key: "sk-test-mock-key",
          anthropic_api_key: "sk-test-mock-key"
        })

      file_path = Path.join(tmp_dir, "lib_test.ex")
      File.write!(file_path, "defmodule TempMod do\n  def old_val, do: 1\nend")

      {:ok, pid} = AgentSupervisor.start_agent(session.id, :coder, project_root: tmp_dir)
      Ecto.Adapters.SQL.Sandbox.allow(IexCode.Repo, self(), pid)

      # Test patch application
      patch = %{
        path: "lib_test.ex",
        target: "def old_val, do: 1",
        replacement: "def new_val, do: 2"
      }

      assert {:ok, patch_summary} =
               CoderAgent.apply_patches(session.id, [patch], project_root: tmp_dir)

      assert patch_summary.applied == 1

      content = File.read!(file_path)
      assert String.contains?(content, "def new_val, do: 2")

      # Test code synthesis call against the mock LLM server
      assert {:ok, code_result} =
               CoderAgent.code(session.id, "Update value to 2",
                 project_root: tmp_dir,
                 session: Map.merge(session, %{model_provider: "openai", model_name: "gpt-4o"})
               )

      assert is_binary(code_result)

      AgentSupervisor.stop_agent(session.id, :coder)
    end
  end

  describe "VerifierAgent GenServer" do
    @tag :tmp_dir
    test "checks compilation and returns verification verdict", %{
      tmp_dir: tmp_dir
    } do
      {:ok, project} =
        Projects.create_project(%{name: "Verifier temp workspace", root_path: tmp_dir})

      {:ok, session} =
        Sessions.create_session(%{project_id: project.id, title: "Verifier temp session"})

      File.write!(Path.join(tmp_dir, "lib_val.ex"), "defmodule LibVal do\n  def ok, do: :ok\nend")

      {:ok, pid} = AgentSupervisor.start_agent(session.id, :verifier, project_root: tmp_dir)
      Ecto.Adapters.SQL.Sandbox.allow(IexCode.Repo, self(), pid)

      assert {:ok, compile_out} = VerifierAgent.check_compile(session.id, project_root: tmp_dir)
      assert is_binary(compile_out)

      state = VerifierAgent.get_state(session.id)
      assert state.status == :idle

      AgentSupervisor.stop_agent(session.id, :verifier)
    end
  end
end
