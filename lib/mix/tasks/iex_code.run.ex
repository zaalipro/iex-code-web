defmodule Mix.Tasks.IexCode.Run do
  @moduledoc """
  Launches a command through the same durable intake used by the application.

      mix iex_code.run [--project PATH|ID] [--session ID] [--request-key KEY]
                       [--priority LEVEL] [--max-attempts N]
                       [--token-budget N] [--cost-budget-cents N]
                       [--time-budget-minutes N] [--agent-max-turns N]
                       [--swarm-agents N] [--swarm-retries N]
                       [--wait] [--timeout SECONDS] [--json] COMMAND...

  `/run`, `/swarm`, `/goal`, and `/research` create durable work. Explicitly
  interactive `/chat` and `/ask` commands are rejected because a Mix task has
  no live conversational transport. Ordinary text also fails when Settings
  routes it to Interactive; use an explicit durable command or select a
  Background default. Research is a paid single-attempt workflow, so
  `--max-attempts` may only be `1` with `/research`. `--wait` is bounded to at
  most 24 hours; its default timeout is five minutes. `--agent-max-turns`
  snapshots the 1..20 model/tool-turn ceiling used by a single-agent run or by
  each durable swarm coder invocation, including every diagnostic repair pass.
  Exact `/help` is parsed and printed without application startup or database-
  backed project/session scope resolution.
  """

  use Mix.Task

  alias IexCode.Execution.{CommandParser, Router}
  alias IexCode.CLI

  @shortdoc "Launches a local durable IexCode command"

  @switches [
    project: :string,
    session: :string,
    request_key: :string,
    priority: :string,
    max_attempts: :integer,
    token_budget: :integer,
    cost_budget_cents: :integer,
    time_budget_minutes: :integer,
    agent_max_turns: :integer,
    swarm_agents: :integer,
    swarm_retries: :integer,
    wait: :boolean,
    timeout: :integer,
    json: :boolean
  ]

  @aliases [p: :project, s: :session, j: :json]

  @impl Mix.Task
  def run(argv) do
    case parse_request(argv) do
      {:ok, _opts, %{kind: :help}, _timeout_seconds} ->
        Mix.shell().info(CommandParser.help_text())

      {:ok, opts, intent, timeout_seconds} ->
        launch(intent, opts, timeout_seconds)

      {:error, reason} ->
        fail(reason)
    end
  end

  defp parse_request(argv) do
    case OptionParser.parse_head(argv, strict: @switches, aliases: @aliases) do
      {_opts, _parts, invalid} when invalid != [] ->
        {:error, {:invalid_options, invalid}}

      {_opts, [], []} ->
        {:error, :missing_command}

      {opts, command_parts, []} ->
        command = Enum.join(command_parts, " ")

        with {:ok, intent} <- CommandParser.parse(command, source: "cli"),
             :ok <- validate_intent_options(intent, opts),
             {:ok, timeout_seconds} <- CLI.validate_timeout_seconds(opts[:timeout]) do
          {:ok, opts, intent, timeout_seconds}
        end
    end
  end

  defp launch(intent, opts, timeout_seconds) do
    CLI.start_app()

    with {:ok, scope} <- CLI.resolve_launch_context(opts),
         context <- %{
           project_id: scope.project.id,
           session_id: scope.session.id,
           settings: scope.settings,
           request_key: opts[:request_key],
           source: "cli",
           wake_dispatcher: false,
           overrides: execution_overrides(opts)
         },
         {:ok, result} <- Router.route(intent, context) do
      handle_result(result, opts, timeout_seconds)
    else
      {:error, reason} -> fail(reason)
    end
  end

  defp handle_result(result, opts, timeout_seconds) do
    with {:ok, run} <- durable_run(result),
         {:ok, final_run} <- maybe_wait(run, opts[:wait], timeout_seconds) do
      print_run(final_run, result, opts[:json])
    else
      {:error, reason} -> fail(reason)
    end
  end

  defp execution_overrides(opts) do
    [
      priority: opts[:priority],
      max_attempts: opts[:max_attempts],
      token_budget: opts[:token_budget],
      cost_budget_cents: opts[:cost_budget_cents],
      time_budget_minutes: opts[:time_budget_minutes],
      agent_max_turns: opts[:agent_max_turns],
      swarm_agent_count: opts[:swarm_agents],
      swarm_max_retries: opts[:swarm_retries]
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp validate_intent_options(%{kind: :research}, opts) do
    case opts[:max_attempts] do
      attempts when attempts in [nil, 1] ->
        :ok

      _attempts ->
        {:error,
         "--max-attempts must be 1 for /research; paid research workflows never retry the whole run"}
    end
  end

  defp validate_intent_options(_intent, _opts), do: :ok

  defp durable_run(%{action: {action, run}}) when action in [:run, :draft], do: {:ok, run}

  defp durable_run(%{action: {:interactive, _prompt, _opts}}),
    do:
      {:error,
       "interactive execution is not supported by mix iex_code.run; ordinary text may resolve to Interactive in Settings, so use /run, /swarm, /goal, /research, or select a Background default"}

  defp durable_run(%{action: {action, _data}}),
    do: {:error, "#{action} is not a durable CLI launch action"}

  defp maybe_wait(run, true, timeout_seconds) do
    if run.status == "draft" do
      {:error, "a draft goal cannot be waited on until it is started"}
    else
      CLI.wait_for_run(run.id, timeout_seconds * 1_000)
    end
  end

  defp maybe_wait(run, _wait, _timeout_seconds), do: {:ok, run}

  defp print_run(run, result, true) do
    payload =
      CLI.run_json(run)
      |> Map.put(:action, elem(result.action, 0))
      |> Map.put(:replayed, result.replayed?)

    Mix.shell().info(Jason.encode!(payload))
  end

  defp print_run(run, result, _json?) do
    replay = if result.replayed?, do: " (idempotent replay)", else: ""

    Mix.shell().info(
      "#{run.id}  #{run.status}  #{run.kind}/#{run.mode}  request=#{run.request_key}#{replay}"
    )
  end

  defp fail({:invalid_options, invalid}) do
    rendered = Enum.map_join(invalid, ", ", fn {option, _value} -> to_string(option) end)
    Mix.raise("invalid options: #{rendered}")
  end

  defp fail(:missing_command),
    do:
      Mix.raise(
        "missing command; usage: mix iex_code.run [--project PATH|ID] [--session ID] COMMAND..."
      )

  defp fail({:wait_timeout, run}),
    do: Mix.raise("wait timeout while run #{run.id} remained #{run.status}")

  defp fail(reason), do: Mix.raise(CLI.format_error(reason))
end
