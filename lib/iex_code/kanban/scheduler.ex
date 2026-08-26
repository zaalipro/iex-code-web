defmodule IexCode.Kanban.Scheduler do
  @moduledoc """
  Supervised poller that turns due Kanban schedules into durable typed runs.

  Claiming and claim recovery live in `IexCode.Kanban`; this process only
  coordinates polling, session resolution, cron calculation, and enqueueing.
  It never depends on a LiveView process being connected.
  """

  use GenServer

  require Logger

  import Ecto.Query, warn: false

  alias IexCode.{Kanban, Repo, Runs, Sessions}
  alias IexCode.Kanban.{Cron, Task}
  alias IexCode.Runs.{Run, RunDispatcher}

  @default_poll_interval 30_000
  @default_stale_after 300_000
  @default_claim_limit 20

  defstruct [
    :name,
    :worker_id,
    :dispatcher,
    :poll_interval,
    :stale_after,
    :claim_limit
  ]

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Runs one recovery/claim/dispatch cycle synchronously."
  def run_now(server \\ __MODULE__), do: GenServer.call(server, :run_now, 60_000)

  @doc "Performs one scheduler cycle without starting a GenServer (useful for operations/tests)."
  def dispatch_due(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now()) |> DateTime.truncate(:second)
    worker_id = Keyword.get(opts, :worker_id, default_worker_id())

    stale_after =
      positive(Keyword.get(opts, :stale_after, @default_stale_after), @default_stale_after)

    claim_limit =
      positive(Keyword.get(opts, :claim_limit, @default_claim_limit), @default_claim_limit)

    dispatcher = Keyword.get(opts, :dispatcher, RunDispatcher)

    recovered = Kanban.recover_stale_schedule_claims(now: now, stale_after: stale_after)

    case Kanban.claim_due_scheduled_tasks(worker_id, now: now, limit: claim_limit) do
      {:ok, tasks} ->
        results = Enum.map(tasks, &dispatch_claimed_task(&1, now, dispatcher))

        %{
          recovered: recovered,
          claimed: length(tasks),
          enqueued: Enum.count(results, &match?({:ok, _}, &1)),
          errors: for({:error, reason} <- results, do: reason),
          results: results
        }

      {:error, reason} ->
        %{recovered: recovered, claimed: 0, enqueued: 0, errors: [reason], results: []}
    end
  end

  @impl true
  def init(opts) do
    settings = Application.get_env(:iex_code, :kanban_scheduler, [])

    state = %__MODULE__{
      name: Keyword.get(opts, :name, __MODULE__),
      worker_id: Keyword.get(opts, :worker_id, default_worker_id()),
      dispatcher: Keyword.get(opts, :dispatcher, RunDispatcher),
      poll_interval:
        positive(
          Keyword.get(opts, :poll_interval, settings[:poll_interval] || @default_poll_interval),
          @default_poll_interval
        ),
      stale_after:
        positive(
          Keyword.get(opts, :stale_after, settings[:stale_after] || @default_stale_after),
          @default_stale_after
        ),
      claim_limit:
        positive(
          Keyword.get(opts, :claim_limit, settings[:claim_limit] || @default_claim_limit),
          @default_claim_limit
        )
    }

    send(self(), :tick)
    {:ok, state}
  end

  @impl true
  def handle_call(:run_now, _from, state) do
    {:reply, run_cycle(state), state}
  end

  @impl true
  def handle_info(:tick, state) do
    result = run_cycle(state)

    if result.errors != [] do
      Logger.warning("Kanban scheduler cycle completed with errors: #{inspect(result.errors)}")
    end

    Process.send_after(self(), :tick, state.poll_interval)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp run_cycle(state) do
    dispatch_due(
      worker_id: state.worker_id,
      dispatcher: state.dispatcher,
      stale_after: state.stale_after,
      claim_limit: state.claim_limit
    )
  rescue
    error ->
      Logger.error("Kanban scheduler cycle crashed: #{Exception.message(error)}")
      %{recovered: 0, claimed: 0, enqueued: 0, errors: [error], results: []}
  catch
    kind, reason ->
      Logger.error("Kanban scheduler cycle crashed: #{inspect({kind, reason})}")
      %{recovered: 0, claimed: 0, enqueued: 0, errors: [{kind, reason}], results: []}
  end

  @doc false
  def dispatch_claimed_task(%Task{} = task, now, dispatcher) do
    schedule_key = Kanban.schedule_occurrence_key(task)

    with {:ok, next_at} <- next_occurrence(task, now),
         {:ok, session} <- resolve_schedule_session(task),
         {:ok, run} <- find_or_enqueue(task, session.id, schedule_key, dispatcher),
         {:ok, _task} <- Kanban.mark_schedule_dispatched(task, run.id, next_at) do
      current_run = Runs.get_run(run.id) || run

      if is_nil(next_at) and
           current_run.status in ["completed", "failed", "cancelled", "interrupted"] do
        _ =
          Kanban.project_run_terminal(
            current_run.id,
            current_run.status,
            current_run.error_message
          )
      end

      {:ok, run}
    else
      {:error, :invalid_cron} = error ->
        _ = Kanban.fail_schedule_claim(task, "Invalid five-field cron expression")
        error

      {:error, reason} = error
      when reason in [:schedule_session_not_found, :schedule_session_project_mismatch] ->
        _ = Kanban.fail_schedule_claim(task, reason)
        error

      {:error, reason} = error ->
        _ = Kanban.release_schedule_claim(task, reason)
        error
    end
  rescue
    error ->
      _ = Kanban.release_schedule_claim(task, error)
      {:error, error}
  end

  @doc false
  def resolve_schedule_session(%Task{session_id: session_id, project_id: project_id} = task) do
    case session_id do
      nil ->
        with {:ok, session} <-
               Sessions.create_session(%{
                 project_id: project_id,
                 title: "Scheduled: #{String.slice(task.title, 0, 180)}",
                 swarm_mode: true
               }) do
          case Kanban.attach_schedule_session(task, session.id) do
            {:ok, _task} ->
              {:ok, session}

            {:error, reason} ->
              _ = Sessions.delete_session(session)
              {:error, reason}
          end
        end

      session_id ->
        case Sessions.get_session(session_id) do
          %{project_id: ^project_id} = session -> {:ok, session}
          nil -> {:error, :schedule_session_not_found}
          _foreign_session -> {:error, :schedule_session_project_mismatch}
        end
    end
  end

  defp next_occurrence(%Task{cron_expression: cron}, _now) when cron in [nil, ""], do: {:ok, nil}

  defp next_occurrence(%Task{cron_expression: cron, scheduled_at: scheduled_at}, now) do
    base = if DateTime.compare(scheduled_at, now) == :gt, do: scheduled_at, else: now
    Cron.next_occurrence(cron, base)
  end

  defp find_or_enqueue(task, session_id, schedule_key, dispatcher) do
    case existing_scheduled_run(task, session_id, schedule_key) do
      nil -> RunDispatcher.enqueue(run_attrs(task, session_id, schedule_key), dispatcher)
      run -> {:ok, run}
    end
  end

  defp existing_scheduled_run(task, session_id, schedule_key) do
    scheduled_for = DateTime.to_iso8601(task.scheduled_at)

    from(run in Run,
      where: run.project_id == ^task.project_id and run.session_id == ^session_id,
      where: run.request_key == ^schedule_key or is_nil(run.request_key),
      where: fragment("json_extract(?, '$.source') = 'kanban_schedule'", run.metadata),
      where: fragment("json_extract(?, '$.kanban_task_id') = ?", run.metadata, ^task.id),
      where: fragment("json_extract(?, '$.schedule_key') = ?", run.metadata, ^schedule_key),
      where: fragment("json_extract(?, '$.scheduled_for') = ?", run.metadata, ^scheduled_for),
      order_by: [
        desc: fragment("? IS NOT NULL", run.request_key),
        asc: run.inserted_at,
        asc: run.id
      ],
      limit: 1
    )
    |> Repo.one()
  end

  defp run_attrs(task, session_id, schedule_key) do
    objective =
      [task.title, task.description]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join("\n\n")

    %{
      project_id: task.project_id,
      session_id: session_id,
      request_key: schedule_key,
      objective: objective,
      kind: "coding_swarm",
      mode: "swarm",
      priority: run_priority(task.priority),
      metadata: %{
        "source" => "kanban_schedule",
        "kanban_task_id" => task.id,
        "schedule_key" => schedule_key,
        "scheduled_for" => DateTime.to_iso8601(task.scheduled_at)
      }
    }
  end

  defp run_priority("critical"), do: "critical"
  defp run_priority("high"), do: "high"
  defp run_priority("low"), do: "low"
  defp run_priority(_), do: "normal"

  defp default_worker_id, do: "schedule:#{node()}:kanban"
  defp positive(value, _default) when is_integer(value) and value > 0, do: value
  defp positive(_value, default), do: default
end
