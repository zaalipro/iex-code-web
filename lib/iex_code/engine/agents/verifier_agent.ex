defmodule IexCode.Engine.Agents.VerifierAgent do
  @moduledoc """
  Dedicated OTP GenServer subagent responsible for compilation verification,
  test suite execution via TestRunner, diagnostic parsing, and emitting structured verdicts.
  """
  use GenServer, restart: :transient
  require Logger
  alias IexCode.Engine.{AgentCancellation, AgentRegistry, AgentStateRetention, OperationManager}
  alias IexCode.{Sessions, Tools}
  alias IexCode.Tools.TestRunner

  @outer_timeout 90_000
  @inner_timeout 60_000
  @lock_retry_interval 25
  @call_completion_margin 250

  # Directories excluded from standalone workspace syntax validation
  @excluded_validate_dirs ~w(_build deps node_modules .git tmp)

  defmodule State do
    defstruct [
      :session_id,
      :session,
      :project_root,
      :control_token,
      :cancel_token,
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
          AgentRegistry.via_tuple(session_id, :verifier)
      end

    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Runs full verification (compilation + test suite execution) for the project workspace.
  Returns `{:ok, summary}` on success or `{:error, {:verification_failed, diagnostics}}` on failure.
  """
  def verify(target, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @outer_timeout)
    GenServer.call(resolve_target(target), {:verify, opts}, timeout)
  end

  @doc """
  Runs the ExUnit test runner for the workspace.
  """
  def run_tests(target, test_opts \\ []) do
    timeout = Keyword.get(test_opts, :timeout, @outer_timeout)
    GenServer.call(resolve_target(target), {:run_tests, test_opts}, timeout)
  end

  @doc """
  Performs a compilation check in the workspace.
  """
  def check_compile(target, compile_opts \\ []) do
    timeout = Keyword.get(compile_opts, :timeout, 60_000)
    GenServer.call(resolve_target(target), {:check_compile, compile_opts}, timeout)
  end

  @doc """
  Returns the current internal state of the VerifierAgent.
  """
  def get_state(target) do
    GenServer.call(resolve_target(target), :get_state)
  end

  defp resolve_target(pid) when is_pid(pid), do: pid

  defp resolve_target(session_id) when is_binary(session_id) do
    AgentRegistry.via_tuple(session_id, :verifier)
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
        role: :verifier,
        generation: opts[:generation]
      })
    end
  end

  @impl true
  def handle_call({:verify, opts}, _from, %State{} = state) do
    session_id = state.session_id
    project_root = opts[:project_root] || state.project_root
    parent_op_id = opts[:parent_op_id]
    project_id = trusted_project_id(opts, state)
    run_id = opts[:run_id]
    workspace_lock_delegation = opts[:workspace_lock_delegation]
    allowed_tools = Keyword.get(opts, :allowed_tools, :all)
    mix_exs_exists = File.exists?(Path.join(project_root, "mix.exs"))

    runtime_owner = Process.get(:iex_code_fleet_owner)

    verify_res =
      IexCode.Engine.FleetRuntime.run(runtime_owner, state.control_token, "verifying", fn ->
        OperationManager.run_sync_operation(
          session_id,
          parent_op_id,
          "VerifierAgent",
          "run_command",
          "Verifier: Checking compilation and test suite",
          %{command: if(mix_exs_exists, do: "mix compile", else: "standalone syntax validation")},
          fn progress ->
            if not tool_allowed?("run_command", allowed_tools) or
                 not tool_allowed?("run_tests", allowed_tools) do
              verification_error(
                :tool_not_allowed,
                "Verification tools are disabled by the run manifest"
              )
            else
              if cancelled_fun(state).() do
                progress.(100, "Verification cancelled")
                verification_error(:cancelled, "Verification cancelled before it started")
              else
                if mix_exs_exists do
                  progress.(20, "Running compilation check...")

                  compile_res =
                    OperationManager.run_sync_operation(
                      session_id,
                      parent_op_id,
                      "VerifierAgent",
                      "run_command",
                      "Verifier: mix compile check",
                      %{command: "mix compile"},
                      fn p ->
                        with_workspace_delegation(workspace_lock_delegation, fn ->
                          Tools.execute(
                            "run_command",
                            %{
                              "command" => "mix compile",
                              "timeout_ms" => 20_000,
                              "project_id" => project_id,
                              "run_id" => run_id,
                              "session_id" => session_id,
                              "agent_name" => "VerifierAgent",
                              "op_id" => parent_op_id
                            },
                            project_root,
                            p
                          )
                        end)
                      end
                    )

                  if cancelled_fun(state).() do
                    progress.(100, "Verification cancelled")
                    verification_error(:cancelled, "Verification cancelled before test run")
                  else
                    progress.(60, "Running test suite...")

                    test_runner_opts = [
                      project_root: project_root,
                      project_id: project_id,
                      run_id: run_id,
                      session_id: session_id,
                      timeout_ms: Keyword.get(opts, :test_timeout_ms, 30_000)
                    ]

                    test_runner_opts =
                      if opts[:test_file],
                        do: Keyword.put(test_runner_opts, :file, opts[:test_file]),
                        else: test_runner_opts

                    test_res =
                      with_workspace_delegation(workspace_lock_delegation, fn ->
                        Tools.run_tests(test_runner_opts)
                      end)

                    progress.(90, "Evaluating verification verdict...")

                    evaluate_mix_verdict(compile_res, test_res, progress)
                  end
                else
                  progress.(40, "Validating Elixir files syntax in workspace...")
                  validate_standalone_workspace(project_root, progress)
                end
              end
            end
          end,
          Keyword.get(opts, :inner_timeout, @inner_timeout)
        )
      end)

    case verify_res do
      {:ok, summary_map} ->
        {last_result, history} = AgentStateRetention.remember(state.history, summary_map)

        new_state = %State{
          state
          | status: :idle,
            last_result: last_result,
            history: history
        }

        {:reply, {:ok, summary_map}, new_state, :hibernate}

      {:error, {:verification_failed, _}} = err ->
        new_state = %State{state | status: :idle, last_result: AgentStateRetention.retain(err)}
        {:reply, err, new_state, :hibernate}

      # Normalize raw timeout/crash reasons into a structured verification failure
      {:error, reason} ->
        err = verification_error(reason, "Verification error: #{format_reason(reason)}")

        new_state = %State{state | status: :idle, last_result: AgentStateRetention.retain(err)}
        {:reply, err, new_state, :hibernate}
    end
  end

  @impl true
  def handle_call({:run_tests, test_opts}, _from, %State{} = state) do
    opts =
      test_opts
      |> Keyword.put_new(:project_root, state.project_root)
      |> Keyword.put(:project_id, trusted_project_id(test_opts, state))
      |> Keyword.put(:session_id, state.session_id)

    res =
      with_workspace_delegation(test_opts[:workspace_lock_delegation], fn ->
        Tools.run_tests(opts)
      end)

    {:reply, res, state, :hibernate}
  end

  @impl true
  def handle_call({:check_compile, compile_opts}, _from, %State{} = state) do
    project_root = compile_opts[:project_root] || state.project_root
    session_id = compile_opts[:session_id] || state.session_id
    project_id = trusted_project_id(compile_opts, state)

    base_args = %{
      "command" => "mix compile",
      "project_id" => project_id,
      "run_id" => compile_opts[:run_id],
      "session_id" => session_id,
      "agent_name" => "VerifierAgent"
    }

    res =
      with_workspace_delegation(compile_opts[:workspace_lock_delegation], fn ->
        wait_timeout =
          compile_opts
          |> Keyword.get(:timeout, 60_000)
          |> Kernel.-(@call_completion_margin)
          |> max(0)

        retry_compile_lock_conflicts(
          fn remaining ->
            # The public compile timeout is an end-to-end budget. Do not silently
            # halve it here: larger workspaces and cold dependency caches can
            # legitimately need more than the default 30 seconds.
            args = Map.put(base_args, "timeout_ms", max(1, min(@inner_timeout, remaining)))
            Tools.execute("run_command", args, project_root, fn _, _ -> :ok end)
          end,
          wait_timeout
        )
      end)

    {:reply, res, state, :hibernate}
  end

  @impl true
  def handle_call(:get_state, _from, %State{} = state) do
    {:reply, state, state, :hibernate}
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

  # A compile check is a cooperative verifier operation. Valid sessions sharing
  # one project serialize behind the project-exclusive command lock instead of
  # failing merely because another verifier got there first. The public
  # `run_tests/2` path intentionally remains fail-closed on a foreign lock.
  defp retry_compile_lock_conflicts(fun, wait_timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + wait_timeout_ms
    do_retry_compile_lock_conflicts(fun, deadline)
  end

  defp do_retry_compile_lock_conflicts(fun, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 1)

    case fun.(remaining) do
      {:error, {:workspace_lock_waiting, _locks}} = waiting ->
        retry_compile_after_conflict(fun, deadline, waiting)

      {:error, {:conflict, _locks}} = waiting ->
        retry_compile_after_conflict(fun, deadline, waiting)

      result ->
        result
    end
  end

  defp retry_compile_after_conflict(fun, deadline, waiting) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining > 0 do
      receive do
      after
        min(@lock_retry_interval, remaining) -> do_retry_compile_lock_conflicts(fun, deadline)
      end
    else
      waiting
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

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)

  defp tool_allowed?(_tool_name, :all), do: true
  defp tool_allowed?(_tool_name, nil), do: true

  defp tool_allowed?(tool_name, allowed_tools) when is_list(allowed_tools),
    do: tool_name in Enum.map(allowed_tools, &to_string/1)

  defp tool_allowed?(_tool_name, _allowed_tools), do: false

  defp verification_error(status, summary) do
    {:error,
     {:verification_failed,
      %{
        status: status,
        summary: summary,
        failures: [],
        compilation_errors: [],
        raw_output: summary
      }}}
  end

  defp evaluate_mix_verdict(compile_res, test_res, progress) do
    case {compile_res, test_res} do
      # run_command reports non-zero exits as {:ok, "Exit Code N:\n..."} — treat as compile failure
      {{:ok, <<"Exit Code ", _::binary>> = comp_out}, _test_res} ->
        progress.(100, "Verification failed: mix compile exited non-zero")
        summary = "Compilation check failed:\n#{comp_out}"

        {:error,
         {:verification_failed,
          %{
            status: :compilation_error,
            summary: summary,
            failures: [],
            compilation_errors: [%{message: comp_out}],
            raw_output: comp_out
          }}}

      {{:ok, comp_out}, {:ok, %TestRunner.Result{status: :passed} = res}} ->
        progress.(100, "Verification passed: All tests and compilation clean.")

        summary =
          "Compilation: OK\nTests: #{res.passed}/#{res.total} passed (#{res.duration_s}s)"

        {:ok, %{status: :passed, summary: summary, result: res, compile_output: comp_out}}

      {{:ok, _comp_out}, {:ok, %TestRunner.Result{status: :failed} = res}} ->
        progress.(100, "Verification failed: #{res.failures_count} test failure(s)")
        summary = "Tests failed: #{res.failures_count}/#{res.total} failures"

        {:error,
         {:verification_failed,
          %{
            status: :failed,
            summary: summary,
            failures: res.failures,
            compilation_errors: [],
            raw_output: res.raw_output,
            result: res
          }}}

      {{:ok, _comp_out}, {:ok, %TestRunner.Result{status: :compilation_error} = res}} ->
        progress.(100, "Verification failed: Compilation error detected during test run")
        summary = "Compilation error in tests: #{length(res.compilation_errors)} error(s)"

        {:error,
         {:verification_failed,
          %{
            status: :compilation_error,
            summary: summary,
            failures: [],
            compilation_errors: res.compilation_errors,
            raw_output: res.raw_output,
            result: res
          }}}

      {{:error, comp_err}, _} ->
        progress.(100, "Verification failed: mix compile error")
        err_str = if is_binary(comp_err), do: comp_err, else: inspect(comp_err)
        summary = "Compilation check failed:\n#{err_str}"

        {:error,
         {:verification_failed,
          %{
            status: :compilation_error,
            summary: summary,
            failures: [],
            compilation_errors: [%{message: err_str}],
            raw_output: err_str
          }}}

      {_, {:error, test_err}} ->
        err_str = if is_binary(test_err), do: test_err, else: inspect(test_err)
        # If mix test failed with non-zero exit or no tests found
        # (word-boundary match so "10 failures" is not mistaken for "0 failures")
        if Regex.match?(~r/\b0 failures\b/, err_str) or String.contains?(err_str, "No tests") do
          progress.(100, "Verification clean (no test failures)")

          {:ok,
           %{
             status: :passed,
             summary: "Compilation OK, no test failures",
             compile_output: ""
           }}
        else
          progress.(100, "Verification failed with error")
          summary = "Test execution error: #{err_str}"

          {:error,
           {:verification_failed,
            %{
              status: :failed,
              summary: summary,
              failures: [],
              compilation_errors: [],
              raw_output: err_str
            }}}
        end
    end
  end

  # run_command wraps non-zero exits as {:ok, "Exit Code N:\n<output>"}
  defp validate_standalone_workspace(project_root, progress) do
    elixir_files =
      Path.wildcard(Path.join(project_root, "**/*.{ex,exs}"))
      |> Enum.reject(fn p ->
        rel = Path.relative_to(p, project_root)
        List.first(Path.split(rel)) in @excluded_validate_dirs
      end)

    if elixir_files == [] do
      progress.(100, "Verification clean (no Elixir files present)")
      {:ok, %{status: :passed, summary: "No Elixir files found to compile", compile_output: ""}}
    else
      results =
        Enum.map(elixir_files, fn file_path ->
          case File.read(file_path) do
            {:ok, content} ->
              check_file_syntax(content, file_path)

            {:error, reason} ->
              {:error,
               %{
                 file: file_path,
                 line: 1,
                 message: "Failed to read file: #{inspect(reason)}"
               }}
          end
        end)

      errors =
        Enum.flat_map(results, fn
          {:error, err} -> [err]
          _ -> []
        end)

      if errors == [] do
        progress.(
          100,
          "Verification passed: All #{length(elixir_files)} files syntactically valid."
        )

        summary = "Syntax check: OK (#{length(elixir_files)} file(s) checked)"
        {:ok, %{status: :passed, summary: summary, compile_output: summary}}
      else
        first_err = List.first(errors)
        progress.(100, "Verification failed: #{length(errors)} syntax error(s)")

        summary =
          "Compilation check failed in #{first_err.file}:#{first_err.line}: #{first_err.message}"

        {:error,
         {:verification_failed,
          %{
            status: :compilation_error,
            summary: summary,
            failures: [],
            compilation_errors: [
              %IexCode.Tools.TestRunner.CompilationError{
                error_type: "SyntaxError",
                file: first_err.file,
                line: first_err.line,
                message: first_err.message,
                raw: summary
              }
            ],
            raw_output: summary
          }}}
      end
    end
  end

  # Syntax-only validation: parse to quoted form without compiling into the app BEAM.
  defp check_file_syntax(content, file_path) do
    try do
      case Code.string_to_quoted(content, file: file_path) do
        {:ok, _ast} ->
          {:ok, file_path}

        {:error, {meta, message, token}} ->
          line =
            cond do
              is_list(meta) -> Keyword.get(meta, :line, 1)
              is_integer(meta) -> meta
              true -> 1
            end

          token_str =
            cond do
              is_binary(token) -> token
              is_list(token) -> to_string(token)
              true -> inspect(token)
            end

          msg =
            case message do
              {prefix, suffix} -> "#{prefix}#{suffix}#{token_str}"
              m when is_binary(m) -> "#{m}#{token_str}"
              other -> "#{inspect(other)}#{token_str}"
            end

          {:error, %{file: file_path, line: line, message: msg}}

        {:error, other} ->
          {:error, %{file: file_path, line: 1, message: inspect(other)}}
      end
    rescue
      e ->
        {:error, %{file: file_path, line: 1, message: format_exception_message(e)}}
    catch
      kind, term ->
        {:error, %{file: file_path, line: 1, message: "#{kind}: #{inspect(term)}"}}
    end
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

  defp format_exception_message(%SyntaxError{description: {prefix, suffix}}) do
    "#{prefix}#{suffix}"
  end

  defp format_exception_message(%SyntaxError{description: desc}) when is_binary(desc) do
    desc
  end

  defp format_exception_message(e) when is_exception(e) do
    try do
      Exception.message(e)
    rescue
      _ -> inspect(e)
    end
  end

  defp format_exception_message(other), do: inspect(other)
end
