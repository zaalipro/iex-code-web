defmodule IexCode.E2E.Case do
  @moduledoc """
  Base ExUnit CaseTemplate for Opaque-Box E2E Testing.
  Provides filesystem sandboxes, temp git repos, PubSub event assertions,
  and LiveView interaction helpers.
  """
  use ExUnit.CaseTemplate
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias IexCode.{Projects, Sessions, Settings}
  alias IexCode.E2E.MockLLMServer

  @endpoint IexCodeWeb.Endpoint

  using do
    quote do
      use IexCodeWeb, :verified_routes

      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import IexCode.E2E.Case
      import IexCode.DataCase, only: [errors_on: 1]

      alias IexCode.{Projects, Sessions, Settings, Tools, LLM}
      alias IexCode.Engine.{SessionServer, SwarmOrchestrator, OperationManager}
      alias IexCode.E2E.MockLLMServer

      @endpoint IexCodeWeb.Endpoint
    end
  end

  setup tags do
    # 0. Drain any lingering processes before test setup
    drain_all_e2e_processes()

    # 1. Setup Database Sandbox via DataCase
    :ok = IexCode.DataCase.setup_sandbox(tags)

    # 2. Setup Filesystem Sandbox
    temp_dir =
      if tags[:workspace_files] do
        create_temp_workspace(tags[:workspace_files])
      else
        create_temp_workspace(%{})
      end

    # 3. Setup Mock LLM Server if tagged
    mock_server_data =
      if tags[:mock_llm] do
        scenario = tags[:llm_scenario] || :standard_completion
        {:ok, server_pid, server_info} = MockLLMServer.start(scenario: scenario)

        # Update settings to point to mock server
        try do
          Settings.update_settings(%{
            openai_base_url: "#{server_info.url}/v1",
            anthropic_base_url: "#{server_info.url}/v1",
            openai_api_key: "mock-test-key",
            anthropic_api_key: "mock-test-key"
          })
        rescue
          _ -> :ok
        catch
          _, _ -> :ok
        end

        {server_pid, server_info}
      else
        nil
      end

    mock_server_pid = if mock_server_data, do: elem(mock_server_data, 0), else: nil
    mock_server_info = if mock_server_data, do: elem(mock_server_data, 1), else: nil

    on_exit(fn ->
      # 1. Drain and terminate all lingering background tasks and supervised processes
      drain_all_e2e_processes()

      # 2. Stop Mock LLM Server if started
      if mock_server_pid && Process.alive?(mock_server_pid) do
        MockLLMServer.stop(mock_server_pid)
      end

      # 3. Cleanup Temp Workspace Directory
      if File.exists?(temp_dir) and !tags[:keep_workspace] do
        File.rm_rf(temp_dir)
      end
    end)

    {:ok,
     conn:
       Phoenix.ConnTest.build_conn()
       |> Map.put(:host, "localhost")
       |> Plug.Test.init_test_session(IexCodeWeb.AdminAuth.session_claims()),
     workspace_path: temp_dir,
     mock_llm: mock_server_info,
     mock_llm_pid: mock_server_pid}
  end

  # --- Filesystem Sandbox Helpers ---

  @doc """
  Creates an isolated temporary workspace directory populated with the given files map.
  Files map format: `%{ "lib/app.ex" => "defmodule App do ... end" }`
  """
  def create_temp_workspace(files \\ %{}) do
    unique_id = Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
    dir = Path.join(System.tmp_dir!(), "iex_code_e2e_#{unique_id}")
    File.mkdir_p!(dir)

    Enum.each(files, fn {rel_path, content} ->
      full_path = Path.join(dir, rel_path)
      File.mkdir_p!(Path.dirname(full_path))
      File.write!(full_path, content)
    end)

    dir
  end

  @doc """
  Initializes a valid git repository inside a temp workspace directory.
  """
  def init_temp_git_repo(files \\ %{}) do
    dir = create_temp_workspace(files)
    System.cmd("git", ["init"], cd: dir)
    System.cmd("git", ["config", "user.name", "IexCode Test"], cd: dir)
    System.cmd("git", ["config", "user.email", "test@iexcode.local"], cd: dir)
    System.cmd("git", ["add", "."], cd: dir)
    System.cmd("git", ["commit", "-m", "Initial commit", "--allow-empty"], cd: dir)
    {:ok, dir}
  end

  def workspace_file_path(workspace_path, relative_path) do
    Path.join(workspace_path, relative_path)
  end

  def workspace_read_file(workspace_path, relative_path) do
    File.read(Path.join(workspace_path, relative_path))
  end

  def workspace_write_file(workspace_path, relative_path, content) do
    full = Path.join(workspace_path, relative_path)
    File.mkdir_p!(Path.dirname(full))
    File.write(full, content)
  end

  # --- PubSub Telemetry Helpers ---

  @doc """
  Subscribes the calling test process to the PubSub channel for a given session.
  """
  def subscribe_session(session_id) do
    Phoenix.PubSub.subscribe(IexCode.PubSub, "session:#{session_id}")
  end

  @doc """
  Drains and returns all queued PubSub messages for the test process.
  """
  def drain_pubsub(acc \\ []) do
    receive do
      msg -> drain_pubsub([msg | acc])
    after
      50 -> Enum.reverse(acc)
    end
  end

  @doc """
  Blocks until session status changes to "idle" or timeout expires.
  """
  def wait_for_session_idle(session_id, timeout \\ 10_000) do
    receive do
      {:session_status_changed, "idle"} -> :ok
      _other -> wait_for_session_idle(session_id, timeout)
    after
      timeout -> {:error, :timeout}
    end
  end

  # --- Test Fixtures ---

  def create_project_fixture(attrs \\ %{}) do
    default_name = "E2E Test Project #{System.unique_integer([:positive])}"
    default_path = create_temp_workspace(%{})

    params =
      attrs
      |> Enum.into(%{
        name: default_name,
        root_path: default_path
      })

    insert_with_retry(fn -> Projects.create_project(params) end)
  end

  def create_session_fixture(project, attrs \\ %{}) do
    project_id = if is_map(project), do: project.id, else: project

    params =
      attrs
      |> Enum.into(%{
        project_id: project_id,
        title: "E2E Test Session #{System.unique_integer([:positive])}",
        swarm_mode: false,
        model_provider: "openai",
        model_name: "gemini-3.7-flash-high"
      })

    insert_with_retry(fn -> Sessions.create_session(params) end)
  end

  defp insert_with_retry(fun, attempts \\ 100) do
    try do
      case fun.() do
        {:ok, struct} ->
          struct

        {:error, _changeset} ->
          if attempts > 1 do
            :timer.sleep(50)
            insert_with_retry(fun, attempts - 1)
          else
            raise "Failed to insert fixture after retries"
          end
      end
    rescue
      e in [Exqlite.Error, DBConnection.ConnectionError] ->
        if attempts > 1 do
          :timer.sleep(50)
          insert_with_retry(fun, attempts - 1)
        else
          reraise e, __STACKTRACE__
        end

      e ->
        if attempts > 1 do
          :timer.sleep(50)
          insert_with_retry(fun, attempts - 1)
        else
          reraise e, __STACKTRACE__
        end
    catch
      _, _ ->
        if attempts > 1 do
          :timer.sleep(50)
          insert_with_retry(fun, attempts - 1)
        else
          raise "Failed to insert fixture after retries"
        end
    end
  end

  def create_message_fixture(session, attrs \\ %{}) do
    session_id = if is_map(session), do: session.id, else: session

    params =
      attrs
      |> Enum.into(%{
        session_id: session_id,
        role: "user",
        content: "Test message #{System.unique_integer([:positive])}",
        agent_name: "User"
      })

    {:ok, message} = Sessions.create_message(params)
    message
  end

  def create_operation_fixture(session, attrs \\ %{}) do
    session_id = if is_map(session), do: session.id, else: session

    params =
      attrs
      |> Enum.into(%{
        session_id: session_id,
        agent_name: "TestAgent",
        op_type: "tool",
        title: "Test Operation #{System.unique_integer([:positive])}",
        status: "running",
        progress: 0,
        started_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    {:ok, operation} = Sessions.create_operation(params)
    operation
  end

  # --- LiveView Interaction Helpers ---

  def mount_workspace(conn, session_id \\ nil) do
    path = if session_id, do: "/sessions/#{session_id}", else: "/"
    live(conn, path)
  end

  def switch_workspace_tab(view, tab_name) do
    render_click(view, "switch_tab", %{"tab" => tab_name})
  end

  def toggle_workspace_swarm(view) do
    render_click(view, "toggle_swarm")
  end

  def submit_workspace_prompt(view, prompt_text) do
    view
    |> form("#prompt-form", %{"prompt" => prompt_text})
    |> render_submit()
  end

  @doc """
  Delegates child process draining to DataCase.drain_all_processes/0.
  """
  def drain_all_e2e_processes do
    IexCode.DataCase.drain_all_processes()
  end
end
