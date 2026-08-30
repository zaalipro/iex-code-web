defmodule IexCodeWeb.InstrumentSummary do
  @moduledoc """
  Pure, bounded projections for the Signal Foundry instrument deck.

  The public builders consume already-projected fact maps. They deliberately do
  not query, enumerate streams, inspect runtime state, or expose identifiers.

  Every builder accepts a trusted internal `destination` scalar. Surface facts
  are: mission (`run`, `phase`, `progress`, `pending_approvals`), board and
  schedule (`status_counts`, `today_count`, `next_scheduled_at`, `error?`),
  research (`run`, `level`, `completed_round`, `source_count`, `result_ready?`),
  changes (`git_status`, `git_error`, `latest_test`), chat (`latest_message`,
  `messages_newer?`), files (`loaded?`, `file_count`, `files_more?`,
  `selected_file`, `dirty?`, `git_relation`), and terminal (`available?`,
  `state`, `active_command`, `latest_command`, `owner`).
  """

  alias IexCode.Kanban.Task

  @surfaces ~w(kanban swarm research calendar changes chat files terminal)
  @statuses [:ready, :active, :attention, :empty, :error, :standby]
  @task_labels %{
    "triage" => "Triage",
    "todo" => "Todo",
    "scheduled" => "Scheduled",
    "ready" => "Ready",
    "running" => "Running",
    "blocked" => "Blocked",
    "review" => "Review",
    "done" => "Done"
  }
  @research_levels %{
    "low" => {"Low", 1},
    "medium" => {"Medium", 2},
    "high" => {"High", 3},
    "ultra" => {"Ultra", 4}
  }

  @type surface :: String.t()
  @type status :: :ready | :active | :attention | :empty | :error | :standby
  @type secondary_fact :: %{required(:label) => String.t(), required(:value) => String.t()}
  @type summary :: %{
          surface: surface(),
          title: String.t(),
          status: status(),
          primary: String.t() | nil,
          secondary: [secondary_fact()],
          detail: String.t() | nil,
          destination: String.t(),
          updated_at: DateTime.t() | nil,
          attention?: boolean()
        }

  @spec build(surface(), map()) :: summary()
  def build(surface, facts) when is_binary(surface) and is_map(facts) do
    unless surface in @surfaces do
      raise ArgumentError, "unsupported instrument surface: #{inspect(surface)}"
    end

    case surface do
      "kanban" -> board(facts)
      "swarm" -> mission(facts)
      "research" -> research(facts)
      "calendar" -> schedule(facts)
      "changes" -> changes(facts)
      "chat" -> chat(facts)
      "files" -> files(facts)
      "terminal" -> terminal(facts)
    end
  end

  def build(surface, _facts),
    do: raise(ArgumentError, "unsupported instrument surface: #{inspect(surface)}")

  @doc "Builds Active Mission from `run`, `phase`, `progress`, and `pending_approvals`."
  @spec mission(map()) :: summary()
  def mission(facts) do
    case field(facts, :run) do
      nil ->
        finalize("swarm", "Active Mission", :empty, "No active run", [], nil, nil, facts)

      run ->
        run_status = normalize_status_text(field(run, :status), "unknown")
        objective = bounded(field(run, :objective))

        phase =
          case bounded_nonblank(field(facts, :phase)) do
            value when is_binary(value) -> value
            _ -> "Status: #{run_status}"
          end

        progress = clamp(field(facts, :progress), 0, 100)
        approvals = nonnegative(field(facts, :pending_approvals))
        status = mission_status(run_status, approvals)

        review =
          if approvals == 0,
            do: "No pending approvals",
            else:
              if(approvals == 1, do: "1 pending approval", else: "#{approvals} pending approvals")

        finalize(
          "swarm",
          "Active Mission",
          status,
          objective,
          [%{label: "Progress", value: "#{progress}%"}, %{label: "Review", value: review}],
          phase,
          field(run, :updated_at),
          facts
        )
    end
  end

  @doc "Builds Mission Board from `status_counts`, `today_count`, `next_scheduled_at`, and `error?`."
  @spec board(map()) :: summary()
  def board(facts) do
    if field(facts, :error?) == true do
      finalize("kanban", "Mission Board", :error, "Board unavailable", [], nil, nil, facts)
    else
      counts = normalized_status_counts(field(facts, :status_counts))
      total = Enum.sum(Map.values(counts))

      secondary =
        Enum.map(
          Task.statuses(),
          &%{
            label: Map.fetch!(@task_labels, &1),
            value: Integer.to_string(Map.fetch!(counts, &1))
          }
        )

      if total == 0 do
        finalize("kanban", "Mission Board", :empty, "No tasks yet", secondary, nil, nil, facts)
      else
        status =
          cond do
            Map.get(counts, "blocked", 0) > 0 -> :attention
            Map.get(counts, "running", 0) > 0 -> :active
            true -> :ready
          end

        noun = if total == 1, do: "task", else: "tasks"

        finalize(
          "kanban",
          "Mission Board",
          status,
          "#{total} #{noun}",
          secondary,
          nil,
          nil,
          facts
        )
      end
    end
  end

  @doc "Builds Research Radar from `run`, `level`, `completed_round`, `source_count`, and `result_ready?`."
  @spec research(map()) :: summary()
  def research(facts) do
    case field(facts, :run) do
      nil ->
        finalize("research", "Research Radar", :empty, "No research runs", [], nil, nil, facts)

      run ->
        run_status = normalize_status_text(field(run, :status), "unknown")
        {level_label, maximum} = research_level(field(facts, :level))
        round = clamp(field(facts, :completed_round), 0, maximum)
        source_count = nonnegative(field(facts, :source_count))
        ready? = field(facts, :result_ready?) == true

        finalize(
          "research",
          "Research Radar",
          research_status(run_status, ready?),
          bounded(field(run, :objective)),
          [
            %{label: "Level", value: level_label},
            %{label: "Round", value: "#{round}/#{maximum} complete"},
            %{label: "Sources", value: Integer.to_string(source_count)},
            %{label: "Result", value: if(ready?, do: "Ready", else: "Pending")}
          ],
          "Research #{run_status}",
          field(run, :updated_at),
          facts
        )
    end
  end

  @doc "Builds Schedule Chronometer from `status_counts`, `today_count`, `next_scheduled_at`, and `error?`."
  @spec schedule(map()) :: summary()
  def schedule(facts) do
    if field(facts, :error?) == true do
      finalize(
        "calendar",
        "Schedule Chronometer",
        :error,
        "Schedule unavailable",
        [],
        nil,
        nil,
        facts
      )
    else
      today_count = nonnegative(field(facts, :today_count))
      next_at = field(facts, :next_scheduled_at)

      next_text =
        if match?(%DateTime{}, next_at),
          do: "Next · #{iso8601(next_at)}",
          else: "No scheduled actions"

      status =
        cond do
          today_count > 0 -> :active
          match?(%DateTime{}, next_at) -> :ready
          true -> :empty
        end

      finalize(
        "calendar",
        "Schedule Chronometer",
        status,
        next_text,
        [%{label: "Today", value: "#{today_count} today"}],
        nil,
        nil,
        facts
      )
    end
  end

  @doc "Builds Change Ledger from `git_status`, `git_error`, and `latest_test`."
  @spec changes(map()) :: summary()
  def changes(facts) do
    cond do
      not is_nil(field(facts, :git_error)) ->
        finalize("changes", "Change Ledger", :error, "Git unavailable", [], nil, nil, facts)

      is_nil(field(facts, :git_status)) ->
        finalize(
          "changes",
          "Change Ledger",
          :standby,
          "Warming · checking Git",
          [],
          nil,
          nil,
          facts
        )

      true ->
        status_data = field(facts, :git_status)
        staged = list_length(field(status_data, :staged))
        unstaged = list_length(field(status_data, :unstaged))
        untracked = list_length(field(status_data, :untracked))
        conflicted = list_length(field(status_data, :conflicted))
        total = staged + unstaged + untracked + conflicted
        truncated? = field(status_data, :truncated?) == true

        status =
          if conflicted > 0 or truncated?,
            do: :attention,
            else: if(total > 0, do: :active, else: :ready)

        noun = if total == 1, do: "change", else: "changes"

        primary =
          if total == 0 and field(status_data, :clean?) == true and not truncated?,
            do: "No changes",
            else: "#{total} #{noun}"

        detail = if truncated?, do: "Showing bounded Git status", else: nil
        test_fact = latest_test_fact(field(facts, :latest_test))

        secondary = [
          %{label: "Branch", value: branch_value(field(status_data, :branch))},
          %{label: "Staged", value: Integer.to_string(staged)},
          %{label: "Unstaged", value: Integer.to_string(unstaged)},
          %{label: "Untracked", value: Integer.to_string(untracked)},
          %{label: "Conflicts", value: Integer.to_string(conflicted)},
          test_fact
        ]

        finalize("changes", "Change Ledger", status, primary, secondary, detail, nil, facts)
    end
  end

  @doc "Builds Conversation Loop from `latest_message` and `messages_newer?`."
  @spec chat(map()) :: summary()
  def chat(facts) do
    case field(facts, :latest_message) do
      nil ->
        finalize("chat", "Conversation Loop", :empty, "No messages yet", [], nil, nil, facts)

      message ->
        secondary =
          []
          |> maybe_append("From", message_from(message))
          |> maybe_append_datetime("Sent", message_timestamp(message))
          |> maybe_append(
            "History",
            if(field(facts, :messages_newer?) == true, do: "Newer messages available", else: nil)
          )

        finalize(
          "chat",
          "Conversation Loop",
          :ready,
          bounded(field(message, :content)),
          secondary,
          nil,
          message_timestamp(message),
          facts
        )
    end
  end

  @doc "Builds File Atlas from `loaded?`, `file_count`, `files_more?`, `selected_file`, `dirty?`, and `git_relation`."
  @spec files(map()) :: summary()
  def files(facts) do
    if field(facts, :loaded?) != true do
      finalize("files", "File Atlas", :standby, "Standby · files not loaded", [], nil, nil, facts)
    else
      count = nonnegative(field(facts, :file_count))

      if count == 0 do
        selected = bounded_nonblank(field(facts, :selected_file)) || "No file selected"
        buffer = if field(facts, :dirty?) == true, do: "Unsaved changes", else: "Saved"
        secondary = [%{label: "Selected", value: selected}, %{label: "Buffer", value: buffer}]
        secondary = maybe_append(secondary, "Git", bounded_nonblank(field(facts, :git_relation)))

        finalize("files", "File Atlas", :empty, "No files discovered", secondary, nil, nil, facts)
      else
        more? = field(facts, :files_more?) == true

        primary =
          if more?,
            do: "500+ files indexed",
            else: "#{count} #{if(count == 1, do: "file", else: "files")} indexed"

        selected = bounded_nonblank(field(facts, :selected_file)) || "No file selected"
        buffer = if field(facts, :dirty?) == true, do: "Unsaved changes", else: "Saved"
        secondary = [%{label: "Selected", value: selected}, %{label: "Buffer", value: buffer}]
        secondary = maybe_append(secondary, "Git", bounded_nonblank(field(facts, :git_relation)))

        status =
          cond do
            field(facts, :dirty?) == true -> :attention
            bounded_nonblank(field(facts, :selected_file)) -> :active
            true -> :ready
          end

        finalize("files", "File Atlas", status, primary, secondary, nil, nil, facts)
      end
    end
  end

  @doc "Builds Terminal Scope from `available?`, `state`, `active_command`, `latest_command`, and `owner`."
  @spec terminal(map()) :: summary()
  def terminal(facts) do
    if field(facts, :available?) != true do
      finalize("terminal", "Terminal Scope", :error, "Terminal unavailable", [], nil, nil, facts)
    else
      state = normalize_state(field(facts, :state))
      active = bounded_nonblank(field(facts, :active_command))
      latest = latest_command(field(facts, :latest_command))
      command = active || latest
      primary = command || "No command yet"
      detail = if active, do: "Command active", else: "Idle · no active command"

      secondary = [
        %{label: "State", value: state_label(state)},
        %{label: "Owner", value: owner_label(field(facts, :owner))}
      ]

      secondary = maybe_append(secondary, "Exit", command_exit(field(facts, :latest_command)))

      status =
        cond do
          state == :error -> :error
          active || state in [:starting, :running, :restarting] -> :active
          state == :stopped -> :standby
          true -> :ready
        end

      finalize("terminal", "Terminal Scope", status, primary, secondary, detail, nil, facts)
    end
  end

  defp finalize(surface, title, status, primary, secondary, detail, updated_at, facts) do
    secondary =
      secondary
      |> Enum.filter(&is_map/1)
      |> Enum.map(fn item ->
        %{label: Map.get(item, :label, ""), value: bounded(Map.get(item, :value)) || ""}
      end)

    %{
      surface: surface,
      title: title,
      status: if(status in @statuses, do: status, else: :standby),
      primary: bounded(primary),
      secondary: secondary,
      detail: bounded(detail),
      destination: destination(facts),
      updated_at: if(match?(%DateTime{}, updated_at), do: updated_at, else: nil),
      attention?: status in [:attention, :error]
    }
  end

  defp destination(facts) do
    case field(facts, :destination) do
      value when is_binary(value) -> String.replace_invalid(value)
      _ -> raise ArgumentError, "instrument summary destination must be a binary"
    end
  end

  defp field(map, key) when is_map(map), do: Map.get(map, key)

  defp field(_map, _key), do: nil

  defp bounded(nil), do: nil

  defp bounded(value) when is_binary(value),
    do: value |> String.replace_invalid() |> String.slice(0, 160)

  defp bounded(_value), do: nil

  defp bounded_nonblank(value) do
    case bounded(value) do
      value when is_binary(value) -> if String.trim(value) == "", do: nil, else: value
      _ -> nil
    end
  end

  defp nonnegative(value) when is_integer(value) and value >= 0, do: value
  defp nonnegative(_value), do: 0

  defp clamp(value, min, max) do
    value = if is_integer(value), do: value, else: 0
    value |> max(min) |> min(max)
  end

  defp normalize_status_text(value, fallback) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: fallback, else: value
  end

  defp normalize_status_text(value, fallback) when is_atom(value) do
    case value do
      :draft -> "draft"
      :queued -> "queued"
      :running -> "running"
      :paused -> "paused"
      :completed -> "completed"
      :failed -> "failed"
      :cancelled -> "cancelled"
      :interrupted -> "interrupted"
      :assistant -> "assistant"
      :user -> "user"
      :system -> "system"
      _ -> fallback
    end
  end

  defp normalize_status_text(_value, fallback), do: fallback

  defp mission_status(status, approvals) do
    cond do
      approvals > 0 or status in ["failed", "interrupted"] -> :attention
      status == "running" -> :active
      status == "paused" -> :attention
      status in ["queued", "draft"] -> :standby
      status == "completed" -> :ready
      status == "cancelled" -> :empty
      true -> :standby
    end
  end

  defp research_status(status, ready?) do
    cond do
      status in ["failed", "interrupted"] -> :attention
      status == "cancelled" -> :empty
      status == "running" -> :active
      status in ["queued", "draft", "paused"] -> :standby
      status == "completed" and ready? -> :ready
      status == "completed" -> :standby
      true -> :standby
    end
  end

  defp normalized_status_counts(counts) when is_map(counts) do
    Map.new(Task.statuses(), fn status -> {status, nonnegative(Map.get(counts, status))} end)
  end

  defp normalized_status_counts(_counts), do: Map.new(Task.statuses(), &{&1, 0})

  defp research_level(value) when is_binary(value) do
    Map.get(@research_levels, String.downcase(String.trim(value)), {"Medium", 2})
  end

  defp research_level(:low), do: {"Low", 1}
  defp research_level(:medium), do: {"Medium", 2}
  defp research_level(:high), do: {"High", 3}
  defp research_level(:ultra), do: {"Ultra", 4}
  defp research_level(value) when is_atom(value), do: {"Medium", 2}

  defp research_level(_value), do: {"Medium", 2}

  defp list_length(value) when is_list(value), do: length(value)
  defp list_length(_value), do: 0

  defp branch_value(value), do: bounded_nonblank(value) || "Unknown"

  defp latest_test_fact(nil), do: %{label: "Tests", value: "No test operation recorded"}

  defp latest_test_fact(operation) do
    status = bounded_nonblank(field(operation, :status)) || "Unknown"
    duration = field(operation, :duration_ms)

    value =
      if is_integer(duration) and duration >= 0 do
        "#{status} · #{duration} ms"
      else
        status
      end

    %{label: "Latest test operation", value: value}
  end

  defp message_from(message) do
    bounded_nonblank(field(message, :agent_name)) ||
      normalize_status_text(field(message, :role), "Unknown")
  end

  defp message_timestamp(message) do
    case field(message, :inserted_at) do
      %DateTime{} = timestamp ->
        timestamp

      _ ->
        if(match?(%DateTime{}, field(message, :updated_at)),
          do: field(message, :updated_at),
          else: nil
        )
    end
  end

  defp latest_command(value) when is_binary(value), do: bounded_nonblank(value)
  defp latest_command(value) when is_map(value), do: bounded_nonblank(field(value, :command))
  defp latest_command(_value), do: nil

  defp command_exit(value) when is_map(value) do
    status = bounded_nonblank(field(value, :status))
    exit_code = field(value, :exit_code)

    cond do
      is_integer(exit_code) and is_binary(status) ->
        "#{String.capitalize(status)} · exit #{exit_code}"

      is_integer(exit_code) ->
        "exit #{exit_code}"

      is_binary(status) ->
        String.capitalize(status)

      true ->
        nil
    end
  end

  defp command_exit(_value), do: nil

  defp normalize_state(value) when is_atom(value) do
    case value do
      :starting -> :starting
      :ready -> :ready
      :running -> :running
      :restarting -> :restarting
      :stopped -> :stopped
      :error -> :error
      _ -> :unknown
    end
  end

  defp normalize_state(value) when is_binary(value) do
    case String.downcase(String.trim(value)) do
      "starting" -> :starting
      "ready" -> :ready
      "running" -> :running
      "restarting" -> :restarting
      "stopped" -> :stopped
      "error" -> :error
      _ -> :unknown
    end
  end

  defp normalize_state(_value), do: :unknown

  defp state_label(:starting), do: "Starting"
  defp state_label(:ready), do: "Ready"
  defp state_label(:running), do: "Running"
  defp state_label(:restarting), do: "Restarting"
  defp state_label(:stopped), do: "Stopped"
  defp state_label(:error), do: "Error"
  defp state_label(:unknown), do: "Unknown"

  defp owner_label(:user), do: "User"

  defp owner_label({:agent, name, _operation_id}),
    do: if(bounded_nonblank(name), do: "Agent · #{bounded_nonblank(name)}", else: "Agent")

  defp owner_label(_owner), do: "Unknown"

  defp iso8601(%DateTime{} = value),
    do: value |> DateTime.shift_zone!("Etc/UTC") |> DateTime.to_iso8601()

  defp maybe_append(list, _label, nil), do: list
  defp maybe_append(list, label, value), do: list ++ [%{label: label, value: value}]

  defp maybe_append_datetime(list, label, %DateTime{} = timestamp),
    do: list ++ [%{label: label, value: iso8601(timestamp)}]

  defp maybe_append_datetime(list, _label, _timestamp), do: list
end
