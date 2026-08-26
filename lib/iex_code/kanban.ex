defmodule IexCode.Kanban do
  @moduledoc """
  Context module for managing Kanban tasks, agent task execution,
  schedules, and real-time PubSub updates.
  """
  import Ecto.Query
  alias Ecto.Changeset
  alias IexCode.Repo
  alias IexCode.Kanban.Task
  alias IexCode.Sessions

  # A running task whose claim is older than this can be re-claimed by another worker.
  @stale_claim_minutes 30
  @default_schedule_claim_limit 20
  @default_schedule_stale_after 300_000

  def list_tasks(project_id, filters \\ %{}) do
    query =
      from(t in Task,
        where: t.project_id == ^project_id,
        order_by: [
          asc:
            fragment(
              "CASE WHEN ? = 'critical' THEN 0 WHEN ? = 'high' THEN 1 WHEN ? = 'medium' THEN 2 ELSE 3 END",
              t.priority,
              t.priority,
              t.priority
            ),
          asc: t.inserted_at
        ]
      )

    query =
      Enum.reduce(filters, query, fn
        {"status", status}, q when status not in ["", nil] ->
          from(t in q, where: t.status == ^status)

        {"priority", priority}, q when priority not in ["", nil] ->
          from(t in q, where: t.priority == ^priority)

        {"assignee", assignee}, q when assignee not in ["", nil] ->
          from(t in q, where: t.assignee == ^assignee)

        {"search", term}, q when term not in ["", nil] ->
          escaped =
            term
            |> String.replace("\\", "\\\\")
            |> String.replace("%", "\\%")
            |> String.replace("_", "\\_")

          pattern = "%#{escaped}%"

          from(t in q,
            where:
              fragment("? LIKE ? ESCAPE '\\'", t.title, ^pattern) or
                fragment("? LIKE ? ESCAPE '\\'", t.description, ^pattern)
          )

        _, q ->
          q
      end)

    Repo.all(query)
  end

  def list_tasks_by_status(project_id) do
    tasks = list_tasks(project_id)
    grouped = Enum.group_by(tasks, & &1.status)

    Enum.into(Task.statuses(), %{}, fn status ->
      {status, Map.get(grouped, status, [])}
    end)
  end

  def get_task!(id), do: Repo.get!(Task, id)

  def get_task(id), do: Repo.get(Task, id)

  @doc "Gets a task only when it belongs to the expected project."
  def get_task(project_id, id) when is_binary(project_id) and is_binary(id),
    do: Repo.get_by(Task, project_id: project_id, id: id)

  def get_task(_project_id, _id), do: nil

  @doc "Gets a task in the expected project or raises when it is absent/out of scope."
  def get_task!(project_id, id) when is_binary(project_id) and is_binary(id),
    do: Repo.get_by!(Task, project_id: project_id, id: id)

  def create_task(attrs) do
    changeset =
      %Task{}
      |> Task.changeset(sanitize_attrs(attrs))
      |> validate_task_session_project()

    if changeset.valid? do
      Repo.retry_on_busy(fn -> Repo.insert(changeset) end)
      |> case do
        {:ok, task} ->
          broadcast(task.project_id, {:task_created, task})
          {:ok, task}

        error ->
          error
      end
    else
      {:error, changeset}
    end
  end

  def update_task(%Task{} = task, attrs) do
    attrs = sanitize_attrs(attrs)

    result =
      Repo.retry_on_busy(fn ->
        Repo.transaction(fn ->
          current = task_snapshot_or_rollback!(task)

          changeset =
            current
            |> Task.changeset(attrs)
            |> reject_task_scope_changes(current)
            |> validate_task_session_project()

          case Repo.update(changeset) do
            {:ok, updated} -> updated
            {:error, changeset} -> Repo.rollback(changeset)
          end
        end)
      end)

    case result do
      {:ok, updated_task} ->
        broadcast(updated_task.project_id, {:task_updated, updated_task})
        {:ok, updated_task}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def move_task_status(%Task{} = task, new_status) do
    normalized = normalize_status(new_status)

    if normalized in Task.statuses() do
      update_task(task, %{status: normalized})
    else
      {:error, :invalid_status}
    end
  end

  def move_task_status(_invalid_task, _status), do: {:error, :invalid_task}

  defp normalize_status(status) when is_binary(status) do
    case String.downcase(String.trim(status)) do
      "in_progress" -> "running"
      "in-progress" -> "running"
      "failed" -> "blocked"
      "complete" -> "done"
      "completed" -> "done"
      s -> s
    end
  end

  defp normalize_status(_), do: nil

  @doc """
  Adds a subtask to a task and recomputes completion progress.
  """
  def add_subtask(%Task{} = task, subtask_params) do
    title =
      case subtask_params do
        %{"title" => t} -> t
        %{title: t} -> t
        t when is_binary(t) -> t
        _ -> ""
      end
      |> to_string()
      |> String.trim()

    if title == "" do
      {:error, :empty_title}
    else
      subtask = %{
        "id" => Ecto.UUID.generate(),
        "title" => title,
        "completed" => false
      }

      current = task.subtasks || []
      update_task(task, %{subtasks: current ++ [subtask]})
    end
  end

  def add_subtask(task_id, subtask_params) when is_binary(task_id) do
    case get_task(task_id) do
      nil -> {:error, :not_found}
      task -> add_subtask(task, subtask_params)
    end
  end

  @doc """
  Toggles the completion status of a subtask.
  """
  def toggle_subtask(%Task{} = task, subtask_id) do
    target_id = to_string(subtask_id)
    current = task.subtasks || []

    updated =
      Enum.map(current, fn s ->
        sid = to_string(s["id"] || s[:id])

        if sid == target_id do
          done? = s["completed"] == true or s[:completed] == true
          Map.put(s, "completed", not done?)
        else
          s
        end
      end)

    update_task(task, %{subtasks: updated})
  end

  def toggle_subtask(task_id, subtask_id) when is_binary(task_id) do
    case get_task(task_id) do
      nil -> {:error, :not_found}
      task -> toggle_subtask(task, subtask_id)
    end
  end

  @doc """
  Deletes a subtask from a task.
  """
  def delete_subtask(%Task{} = task, subtask_id) do
    target_id = to_string(subtask_id)
    current = task.subtasks || []

    updated =
      Enum.reject(current, fn s ->
        sid = to_string(s["id"] || s[:id])
        sid == target_id
      end)

    update_task(task, %{subtasks: updated})
  end

  def delete_subtask(task_id, subtask_id) when is_binary(task_id) do
    case get_task(task_id) do
      nil -> {:error, :not_found}
      task -> delete_subtask(task, subtask_id)
    end
  end

  def delete_task(%Task{} = task) do
    result =
      Repo.retry_on_busy(fn ->
        Repo.transaction(fn ->
          current = task_snapshot_or_rollback!(task)

          case Repo.delete(current) do
            {:ok, deleted} -> deleted
            {:error, changeset} -> Repo.rollback(changeset)
          end
        end)
      end)

    case result do
      {:ok, deleted_task} ->
        broadcast(deleted_task.project_id, {:task_deleted, deleted_task})
        {:ok, deleted_task}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def change_task(%Task{} = task, attrs \\ %{}) do
    Task.changeset(task, sanitize_attrs(attrs))
  end

  @doc """
  Atomically claims a task for the given assignee.

  The claim is a single conditional UPDATE: it only succeeds when the task is
  not already running, or when an existing claim is older than
  #{@stale_claim_minutes} minutes (stale-claim reclamation). Returns
  `{:ok, task}` on success or `{:error, :already_claimed}` when another worker
  holds a fresh claim.
  """
  def claim_task(%Task{} = task, assignee \\ "default") do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    stale_before = DateTime.add(now, -@stale_claim_minutes * 60, :second)
    worker_pid = inspect(self())

    {count, _} =
      from(t in Task,
        where: t.id == ^task.id,
        where: t.project_id == ^task.project_id,
        where: t.status != "running" or is_nil(t.claimed_at) or t.claimed_at < ^stale_before
      )
      |> task_session_scope(task.session_id)
      |> Repo.update_all(
        set: [
          status: "running",
          assignee: assignee,
          worker_pid: worker_pid,
          claimed_at: now,
          updated_at: now
        ]
      )

    case count do
      1 ->
        claimed = get_task!(task.id)
        broadcast(claimed.project_id, {:task_updated, claimed})
        {:ok, claimed}

      0 ->
        case task_snapshot(task) do
          {:ok, _current} -> {:error, :already_claimed}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc """
  Atomically claims due scheduled tasks for a scheduler worker.

  Each conditional update requires the row to still be in `scheduled` state
  with the same due timestamp, so concurrent scheduler processes cannot claim
  the same occurrence. The original `scheduled_at` is retained as the durable
  occurrence identity until dispatch is acknowledged.
  """
  def claim_due_scheduled_tasks(worker_id, opts \\ [])

  def claim_due_scheduled_tasks(worker_id, opts) when is_binary(worker_id) do
    now = schedule_now(opts)
    limit = positive_option(opts[:limit], @default_schedule_claim_limit, 100)
    owner = schedule_worker_id(worker_id)

    result =
      Repo.retry_on_busy(fn ->
        Repo.transaction(fn ->
          candidates =
            from(t in Task,
              where: t.status == "scheduled",
              where: not is_nil(t.scheduled_at) and t.scheduled_at <= ^now,
              order_by: [asc: t.scheduled_at, asc: t.inserted_at, asc: t.id],
              limit: ^limit
            )
            |> Repo.all()

          Enum.reduce(candidates, [], fn candidate, claimed ->
            {count, _} =
              from(t in Task,
                where: t.id == ^candidate.id,
                where: t.status == "scheduled",
                where: t.scheduled_at == ^candidate.scheduled_at
              )
              |> Repo.update_all(
                set: [
                  status: "running",
                  worker_pid: owner,
                  claimed_at: now,
                  latest_summary: "Scheduled occurrence claimed for durable dispatch",
                  updated_at: now
                ]
              )

            if count == 1, do: [Repo.get!(Task, candidate.id) | claimed], else: claimed
          end)
          |> Enum.reverse()
        end)
      end)

    case result do
      {:ok, claimed} ->
        Enum.each(claimed, &broadcast(&1.project_id, {:task_updated, &1}))
        {:ok, claimed}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def claim_due_scheduled_tasks(_worker_id, _opts), do: {:error, :invalid_worker_id}

  @doc """
  Releases stale scheduler-owned claims back to `scheduled`.

  Claims made by users or ordinary agents are never matched: scheduler owners
  always use the reserved `schedule:` prefix.
  """
  def recover_stale_schedule_claims(opts \\ []) do
    now = schedule_now(opts)
    stale_after = positive_option(opts[:stale_after], @default_schedule_stale_after, :infinity)
    stale_before = DateTime.add(now, -stale_after, :millisecond)

    {count, _} =
      Repo.retry_on_busy(fn ->
        from(t in Task,
          where: t.status == "running",
          where: like(t.worker_pid, "schedule:%"),
          where: is_nil(t.claimed_at) or t.claimed_at <= ^stale_before
        )
        |> Repo.update_all(
          set: [
            status: "scheduled",
            worker_pid: nil,
            claimed_at: nil,
            latest_summary: "Recovered stale schedule dispatch claim",
            updated_at: now
          ]
        )
      end)

    count
  end

  @doc "Returns the stable idempotency key for a claimed scheduled occurrence."
  def schedule_occurrence_key(%Task{id: id, scheduled_at: %DateTime{} = scheduled_at}) do
    "kanban:#{id}:#{DateTime.to_iso8601(scheduled_at)}"
  end

  def schedule_occurrence_key(_task), do: nil

  @doc "Attaches a newly-created session to a live scheduler claim if none is attached."
  def attach_schedule_session(%Task{} = task, session_id) when is_binary(session_id) do
    case Sessions.get_session(session_id) do
      %{project_id: project_id} when project_id == task.project_id ->
        {count, _} =
          from(t in Task,
            where: t.id == ^task.id,
            where: t.project_id == ^project_id,
            where: t.status == "running",
            where: t.worker_pid == ^task.worker_pid,
            where: is_nil(t.session_id)
          )
          |> Repo.update_all(
            set: [
              session_id: session_id,
              updated_at: DateTime.utc_now() |> DateTime.truncate(:second)
            ]
          )

        case count do
          1 -> {:ok, get_task!(task.id)}
          0 -> {:error, :schedule_claim_lost}
        end

      nil ->
        {:error, :schedule_session_not_found}

      _foreign_session ->
        {:error, :schedule_session_project_mismatch}
    end
  end

  @doc "Acknowledges a durable run enqueue and advances a recurring schedule."
  def mark_schedule_dispatched(%Task{} = task, run_id, next_scheduled_at)
      when is_binary(run_id) and
             (is_nil(next_scheduled_at) or is_struct(next_scheduled_at, DateTime)) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    attrs =
      if next_scheduled_at do
        [
          status: "scheduled",
          scheduled_at: DateTime.truncate(next_scheduled_at, :second),
          worker_pid: nil,
          claimed_at: nil,
          latest_summary: "Enqueued durable run #{run_id}; next occurrence scheduled",
          updated_at: now
        ]
      else
        [
          status: "running",
          worker_pid: "run:#{run_id}",
          latest_summary: "Enqueued durable run #{run_id}",
          updated_at: now
        ]
      end

    result =
      Repo.retry_on_busy(fn ->
        Repo.transaction(fn ->
          current =
            from(t in Task,
              where: t.id == ^task.id,
              where: t.status == "running",
              where: t.worker_pid == ^task.worker_pid,
              where: t.scheduled_at == ^task.scheduled_at,
              where: t.claimed_at == ^task.claimed_at
            )
            |> Repo.one()

          if is_nil(current), do: Repo.rollback(:schedule_claim_lost)

          run = Repo.get(IexCode.Runs.Run, run_id)
          occurrence_key = schedule_occurrence_key(current)

          unless scheduled_run_matches?(run, current, occurrence_key) do
            Repo.rollback(:schedule_run_mismatch)
          end

          {count, _} =
            from(t in Task,
              where: t.id == ^current.id,
              where: t.status == "running",
              where: t.worker_pid == ^current.worker_pid,
              where: t.project_id == ^current.project_id,
              where: t.session_id == ^current.session_id,
              where: t.scheduled_at == ^current.scheduled_at
            )
            |> Repo.update_all(set: attrs)

          if count == 1,
            do: Repo.get!(Task, current.id),
            else: Repo.rollback(:schedule_claim_lost)
        end)
      end)

    case result do
      {:ok, %Task{} = updated} ->
        broadcast(updated.project_id, {:task_updated, updated})
        {:ok, updated}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Releases a scheduler claim after a transient enqueue failure."
  def release_schedule_claim(%Task{} = task, reason \\ :enqueue_failed) do
    update_schedule_claim(task,
      status: "scheduled",
      worker_pid: nil,
      claimed_at: nil,
      latest_summary: "Schedule dispatch deferred: #{format_schedule_reason(reason)}",
      updated_at: DateTime.utc_now() |> DateTime.truncate(:second)
    )
  end

  @doc "Moves a scheduler claim to blocked after a non-retryable schedule error."
  def fail_schedule_claim(%Task{} = task, reason) do
    update_schedule_claim(task,
      status: "blocked",
      worker_pid: nil,
      claimed_at: nil,
      latest_summary: "Schedule dispatch blocked: #{format_schedule_reason(reason)}",
      updated_at: DateTime.utc_now() |> DateTime.truncate(:second)
    )
  end

  @doc """
  Projects a durable run's terminal state onto its one-off Kanban task.

  The conditional update is deliberately strict: only a task that is still
  `running` and still owned by `run:<run_id>` may be consumed. Recurring rows
  have already advanced back to `scheduled` with their claim cleared, so a
  previous occurrence can never overwrite the next occurrence.

  Returns `{:ok, task}` when projected and `:noop` when the link was already
  cleared or moved by a concurrent actor.
  """
  def project_run_terminal(run_id, terminal_status, summary \\ nil)

  def project_run_terminal(run_id, terminal_status, summary)
      when is_binary(run_id) and
             terminal_status in ["completed", "failed", "cancelled", "interrupted"] do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    owner = "run:#{run_id}"
    task_status = if terminal_status == "completed", do: "done", else: "blocked"
    latest_summary = terminal_run_summary(run_id, terminal_status, summary)

    result =
      Repo.retry_on_busy(fn ->
        Repo.transaction(fn ->
          candidate_id =
            from(t in Task,
              where: t.status == "running",
              where: t.worker_pid == ^owner,
              order_by: [asc: t.inserted_at, asc: t.id],
              select: t.id,
              limit: 1
            )
            |> Repo.one()

          if candidate_id do
            {count, _} =
              from(t in Task,
                where: t.id == ^candidate_id,
                where: t.status == "running",
                where: t.worker_pid == ^owner
              )
              |> Repo.update_all(
                set: [
                  status: task_status,
                  worker_pid: nil,
                  claimed_at: nil,
                  latest_summary: latest_summary,
                  updated_at: now
                ]
              )

            if count == 1, do: Repo.get!(Task, candidate_id), else: nil
          end
        end)
      end)

    case result do
      {:ok, nil} ->
        :noop

      {:ok, %Task{} = task} ->
        broadcast(task.project_id, {:task_updated, task})
        {:ok, task}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def project_run_terminal(_run_id, _terminal_status, _summary),
    do: {:error, :invalid_run_terminal_status}

  def estimate_effort(%Task{} = task) do
    estimate =
      cond do
        task.steps_total > 5 -> "25-45m (High effort)"
        task.steps_total > 2 -> "10-20m (Medium effort)"
        true -> "3-5m (Low effort)"
      end

    update_task(task, %{estimate: estimate})
  end

  def broadcast(project_id, event) do
    Phoenix.PubSub.broadcast(IexCode.PubSub, "kanban:#{project_id}", event)
  end

  def subscribe(project_id) do
    Phoenix.PubSub.subscribe(IexCode.PubSub, "kanban:#{project_id}")
  end

  defp sanitize_attrs(attrs) when is_map(attrs) do
    Sessions.sanitize_utf8(attrs)
  end

  defp sanitize_attrs(attrs), do: attrs

  defp task_snapshot(%Task{id: id, project_id: project_id, session_id: session_id})
       when is_binary(id) and is_binary(project_id) do
    current =
      Task
      |> where([task], task.id == ^id and task.project_id == ^project_id)
      |> task_session_scope(session_id)
      |> Repo.one()

    case current do
      %Task{} ->
        {:ok, current}

      nil ->
        if Repo.exists?(from(task in Task, where: task.id == ^id)),
          do: {:error, :task_scope_mismatch},
          else: {:error, :not_found}
    end
  end

  defp task_snapshot(%Task{}), do: {:error, :task_scope_mismatch}

  defp task_snapshot_or_rollback!(%Task{} = task) do
    case task_snapshot(task) do
      {:ok, current} -> current
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp task_session_scope(query, nil), do: where(query, [task], is_nil(task.session_id))

  defp task_session_scope(query, session_id) when is_binary(session_id),
    do: where(query, [task], task.session_id == ^session_id)

  defp task_session_scope(query, _invalid), do: where(query, false)

  defp validate_task_session_project(%Changeset{} = changeset) do
    project_id = Changeset.get_field(changeset, :project_id)
    session_id = Changeset.get_field(changeset, :session_id)

    case {project_id, session_id} do
      {_project_id, nil} ->
        changeset

      {project_id, session_id} when is_binary(project_id) and is_binary(session_id) ->
        case Sessions.get_session(session_id) do
          %{project_id: ^project_id} ->
            changeset

          nil ->
            Changeset.add_error(changeset, :session_id, "does not exist")

          _foreign ->
            Changeset.add_error(changeset, :session_id, "must belong to the task project")
        end

      {_project_id, _session_id} ->
        Changeset.add_error(changeset, :session_id, "is invalid")
    end
  end

  defp reject_task_scope_changes(%Changeset{} = changeset, %Task{} = task) do
    changeset
    |> reject_task_scope_change(:project_id, task.project_id)
    |> reject_task_scope_change(:session_id, task.session_id)
  end

  defp reject_task_scope_change(%Changeset{} = changeset, field, persisted) do
    case Changeset.fetch_change(changeset, field) do
      {:ok, requested} when requested != persisted ->
        Changeset.add_error(changeset, field, "cannot be changed after creation")

      _unchanged ->
        changeset
    end
  end

  defp scheduled_run_matches?(%IexCode.Runs.Run{} = run, %Task{} = task, occurrence_key)
       when is_binary(occurrence_key) do
    metadata = run.metadata || %{}

    request_identity_matches? = run.request_key == occurrence_key or is_nil(run.request_key)

    run.project_id == task.project_id and run.session_id == task.session_id and
      request_identity_matches? and metadata_value(metadata, "source") == "kanban_schedule" and
      metadata_value(metadata, "kanban_task_id") == task.id and
      metadata_value(metadata, "schedule_key") == occurrence_key and
      metadata_value(metadata, "scheduled_for") == DateTime.to_iso8601(task.scheduled_at)
  end

  defp scheduled_run_matches?(_run, _task, _occurrence_key), do: false

  defp metadata_value(metadata, "kanban_task_id"),
    do: Map.get(metadata, "kanban_task_id") || Map.get(metadata, :kanban_task_id)

  defp metadata_value(metadata, "source"),
    do: Map.get(metadata, "source") || Map.get(metadata, :source)

  defp metadata_value(metadata, "schedule_key"),
    do: Map.get(metadata, "schedule_key") || Map.get(metadata, :schedule_key)

  defp metadata_value(metadata, "scheduled_for"),
    do: Map.get(metadata, "scheduled_for") || Map.get(metadata, :scheduled_for)

  defp update_schedule_claim(%Task{} = task, attrs) do
    {count, _} =
      from(t in Task,
        where: t.id == ^task.id,
        where: t.project_id == ^task.project_id,
        where: t.status == "running",
        where: t.worker_pid == ^task.worker_pid,
        where: t.scheduled_at == ^task.scheduled_at,
        where: t.claimed_at == ^task.claimed_at
      )
      |> Repo.update_all(set: attrs)

    case count do
      1 ->
        updated = get_task!(task.id)
        broadcast(updated.project_id, {:task_updated, updated})
        {:ok, updated}

      0 ->
        {:error, :schedule_claim_lost}
    end
  end

  defp schedule_worker_id("schedule:" <> _ = worker_id), do: worker_id
  defp schedule_worker_id(worker_id), do: "schedule:#{worker_id}"

  defp schedule_now(opts) do
    case opts[:now] do
      %DateTime{} = now -> now |> DateTime.shift_zone!("Etc/UTC") |> DateTime.truncate(:second)
      _ -> DateTime.utc_now() |> DateTime.truncate(:second)
    end
  end

  defp positive_option(value, _default, max)
       when is_integer(value) and value > 0 and (max == :infinity or value <= max),
       do: value

  defp positive_option(_value, default, _max), do: default

  defp format_schedule_reason(reason) when is_binary(reason), do: String.slice(reason, 0, 500)
  defp format_schedule_reason(reason), do: reason |> inspect() |> String.slice(0, 500)

  defp terminal_run_summary(run_id, "completed", _summary),
    do: "Durable run #{run_id} completed successfully"

  defp terminal_run_summary(run_id, status, summary) do
    detail =
      case summary do
        value when is_binary(value) and value != "" -> String.slice(value, 0, 400)
        _ -> default_terminal_detail(status)
      end

    "Durable run #{run_id} #{status}: #{detail}"
  end

  defp default_terminal_detail("failed"), do: "Execution failed; inspect the run journal"
  defp default_terminal_detail("cancelled"), do: "Cancelled by user"
  defp default_terminal_detail("interrupted"), do: "Worker interrupted; manual retry required"
end
