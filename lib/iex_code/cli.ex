defmodule IexCode.CLI do
  @moduledoc false

  alias IexCode.{Projects, Runs, Sessions, Settings}
  alias IexCode.Execution.Router

  @default_wait_timeout_ms 300_000
  @maximum_wait_timeout_ms 86_400_000

  def start_app do
    # Mix commands are short-lived database clients. Starting a private
    # dispatcher here can steal queued work from the long-running web server
    # node immediately before this BEAM exits.
    Application.put_env(:iex_code, :start_run_dispatcher, false)
    Application.put_env(:iex_code, :start_kanban_scheduler, false)
    Mix.Task.run("app.start")
    :ok
  end

  def enqueue_run_control(run, kind, payload, request_key \\ nil)

  def enqueue_run_control(run, kind, payload, request_key)
      when kind in ["pause", "resume", "steer"] and is_map(payload) do
    request_key = request_key || "cli-control:#{Ecto.UUID.generate()}"

    with :ok <- validate_control_state(run, kind),
         {:ok, control} <-
           Runs.enqueue_control(run, request_key, %{
             kind: kind,
             payload: payload,
             requested_by: "local-cli"
           }) do
      {:ok, {run, control}}
    end
  end

  def enqueue_run_control(_run, _kind, _payload, _request_key),
    do: {:error, :invalid_control_request}

  defp validate_control_state(%{status: "running"}, "pause"), do: :ok
  defp validate_control_state(%{status: "paused"}, "resume"), do: :ok

  defp validate_control_state(%{execution_engine: "dag_v1"}, "steer"),
    do: {:error, :dag_steering_unsupported}

  defp validate_control_state(%{kind: kind, status: status}, "steer")
       when kind in ["coding_agent", "coding_swarm"] and status in ["running", "paused"],
       do: :ok

  defp validate_control_state(%{status: status}, kind),
    do: {:error, {:invalid_transition, status, kind}}

  def resolve_launch_context(opts) when is_list(opts) do
    settings = Settings.get_settings()

    case opts[:session] do
      session_id when is_binary(session_id) ->
        with {:ok, session} <- fetch_session(session_id),
             {:ok, project} <- project_for_session(session, opts[:project]),
             true <- session.project_id == project.id or {:error, :session_project_mismatch} do
          {:ok, %{project: project, session: session, settings: settings}}
        end

      _no_session ->
        with {:ok, project} <- resolve_project(opts[:project] || File.cwd!(), create?: true),
             {:ok, session} <- reuse_or_create_session(project) do
          {:ok, %{project: project, session: session, settings: settings}}
        end
    end
  end

  def resolve_project(reference, opts \\ [])

  def resolve_project(reference, opts) when is_binary(reference) and is_list(opts) do
    create? = Keyword.get(opts, :create?, false)

    case project_by_id(reference) do
      {:ok, project} ->
        {:ok, project}

      {:error, :project_not_found} ->
        resolve_project_path(reference, create?)
    end
  end

  def resolve_project(_reference, _opts), do: {:error, :invalid_project_reference}

  def wait_for_run(run_id, timeout_ms \\ @default_wait_timeout_ms)

  def wait_for_run(run_id, timeout_ms)
      when is_binary(run_id) and is_integer(timeout_ms) and timeout_ms > 0 and
             timeout_ms <= @maximum_wait_timeout_ms do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_run(run_id, deadline)
  end

  def wait_for_run(_run_id, _timeout_ms), do: {:error, :invalid_wait_timeout}

  def run_json(run) do
    %{
      id: run.id,
      project_id: run.project_id,
      session_id: run.session_id,
      kind: run.kind,
      mode: run.mode,
      status: run.status,
      priority: run.priority,
      progress: run.progress,
      request_key: run.request_key,
      attempt: run.attempt,
      max_attempts: run.max_attempts,
      input_tokens: run.input_tokens,
      output_tokens: run.output_tokens,
      cost_cents: run.cost_cents,
      inserted_at: encode_datetime(run.inserted_at),
      started_at: encode_datetime(run.started_at),
      completed_at: encode_datetime(run.completed_at),
      error_message: run.error_message
    }
  end

  def format_error(%{__struct__: IexCode.Execution.CommandError, message: message}), do: message
  def format_error(%{__struct__: IexCode.Execution.PolicyError, message: message}), do: message

  def format_error(%Ecto.Changeset{} = changeset) do
    Enum.map_join(changeset.errors, ", ", fn {field, {message, _opts}} ->
      "#{field} #{message}"
    end)
  end

  def format_error({:invalid_transition, from, to})
      when is_binary(from) and is_binary(to),
      do: "invalid_transition: #{from} -> #{to}"

  def format_error({reason, details}) when is_atom(reason),
    do: "#{reason}: #{safe_details(details)}"

  def format_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  def format_error(reason) when is_binary(reason), do: reason
  def format_error(_reason), do: "operation_failed"

  def validate_timeout_seconds(nil), do: {:ok, div(@default_wait_timeout_ms, 1_000)}

  def validate_timeout_seconds(seconds)
      when is_integer(seconds) and seconds > 0 and seconds <= div(@maximum_wait_timeout_ms, 1_000),
      do: {:ok, seconds}

  def validate_timeout_seconds(_seconds), do: {:error, :invalid_wait_timeout}

  def terminal_status?(status), do: status in Router.terminal_statuses()

  defp fetch_session(session_id) do
    case Sessions.get_session(session_id) do
      nil -> {:error, :session_not_found}
      session -> {:ok, session}
    end
  rescue
    _error -> {:error, :session_not_found}
  end

  defp project_for_session(session, nil) do
    try do
      {:ok, Projects.get_project!(session.project_id)}
    rescue
      _error -> {:error, :project_not_found}
    end
  end

  defp project_for_session(_session, project_reference),
    do: resolve_project(project_reference, create?: false)

  defp project_by_id(reference) do
    case Ecto.UUID.cast(reference) do
      {:ok, id} ->
        try do
          {:ok, Projects.get_project!(id)}
        rescue
          _error -> {:error, :project_not_found}
        end

      :error ->
        {:error, :project_not_found}
    end
  end

  defp resolve_project_path(reference, create?) do
    expanded = Path.expand(reference)

    cond do
      not File.dir?(expanded) ->
        {:error, :project_path_not_found}

      create? ->
        Projects.get_or_create_project(expanded, Path.basename(expanded))

      project = Projects.get_project_by_path(expanded) ->
        {:ok, project}

      true ->
        {:error, :project_not_found}
    end
  end

  defp reuse_or_create_session(project) do
    case Sessions.list_sessions_for_project(project.id) do
      [session | _rest] ->
        {:ok, session}

      [] ->
        Sessions.create_session(%{project_id: project.id, title: "CLI Session"})
    end
  end

  defp do_wait_for_run(run_id, deadline) do
    case Runs.get_run(run_id) do
      nil ->
        {:error, :run_not_found}

      run ->
        if terminal_status?(run.status) do
          {:ok, run}
        else
          remaining = deadline - System.monotonic_time(:millisecond)

          if remaining <= 0 do
            {:error, {:wait_timeout, run}}
          else
            receive do
              _message -> do_wait_for_run(run_id, deadline)
            after
              min(remaining, 250) -> do_wait_for_run(run_id, deadline)
            end
          end
        end
    end
  end

  defp safe_details(details) when is_atom(details), do: Atom.to_string(details)
  defp safe_details(details) when is_binary(details), do: String.slice(details, 0, 500)
  defp safe_details(_details), do: "invalid_details"

  defp encode_datetime(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp encode_datetime(nil), do: nil
end
