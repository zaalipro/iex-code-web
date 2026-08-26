defmodule IexCode.Execution.Router do
  @moduledoc """
  Shared intake boundary for composer, local CLI, and other trusted-local callers.

  The router parses a command once, resolves a secret-free execution policy once,
  validates the project/session scope, and then either returns a process-local
  action or creates an idempotent durable run. Durable callers receive the
  generated request key so that an ambiguous client retry can submit the exact
  same request safely.

  No credentials, provider endpoints, or arbitrary settings maps are copied into
  run metadata. The only settings-derived value persisted here is the validated
  `execution_policy` returned by `IexCode.Execution.Policy`.
  """

  alias IexCode.Execution.{CommandParser, DagTemplate, Intent, Policy}
  alias IexCode.Research.Launch, as: ResearchLaunch
  alias IexCode.Research.Results, as: ResearchResults
  alias IexCode.Runs.RunDispatcher
  alias IexCode.{Projects, Runs, Sessions, Settings}

  @max_request_key_bytes 200
  @terminal_statuses ~w(completed failed cancelled interrupted)
  @metadata_secret_fragments ~w(
    api_key
    authorization
    base_url
    cookie
    credential
    endpoint
    password
    private_key
    secret
    token
  )

  @type context :: map()
  @type result :: %{
          required(:action) => tuple(),
          required(:intent) => Intent.t(),
          required(:request_key) => String.t() | nil,
          optional(:run) => struct() | nil,
          optional(:replayed?) => boolean(),
          optional(:message) => struct() | nil
        }

  @doc "Routes raw command text or a pre-parsed intent through the shared intake boundary."
  @spec route(String.t() | Intent.t(), context()) :: {:ok, result()} | {:error, term()}
  def route(command_or_intent, context) when is_map(context) do
    with {:ok, intent} <- normalize_intent(command_or_intent, context),
         {:ok, scope} <- resolve_scope(context),
         {:ok, policy} <- resolve_policy(scope, context),
         :ok <- validate_intent(intent) do
      dispatch_intent(intent, scope, policy, context)
    end
  end

  def route(_command_or_intent, _context), do: {:error, :invalid_execution_context}

  @doc "Alias retained for callers that describe intake as a launch operation."
  def launch(command_or_intent, context), do: route(command_or_intent, context)

  @doc "Alias retained for transport adapters that describe intake as dispatch."
  def dispatch(command_or_intent, context), do: route(command_or_intent, context)

  @doc "The terminal run states used by local CLI wait loops."
  def terminal_statuses, do: @terminal_statuses

  defp normalize_intent(%Intent{} = intent, _context), do: {:ok, intent}

  defp normalize_intent(command, context) when is_binary(command) do
    CommandParser.parse(command, source: value(context, :source) || "router")
  end

  defp normalize_intent(_command, _context), do: {:error, :invalid_execution_intent}

  defp resolve_scope(context) do
    project_id = id(value(context, :project_id))
    session_id = id(value(context, :session_id))

    with true <- is_binary(project_id) or {:error, :invalid_project_id},
         true <- is_binary(session_id) or {:error, :invalid_session_id},
         {:ok, project} <- fetch_project(project_id),
         {:ok, session} <- fetch_session(session_id),
         true <- session.project_id == project.id or {:error, :session_project_mismatch},
         settings when is_map(settings) <- value(context, :settings) || Settings.get_settings(),
         :ok <- persisted_settings(settings) do
      {:ok, %{project: project, session: session, settings: settings}}
    else
      {:error, _reason} = error -> error
      false -> {:error, :invalid_execution_scope}
      _invalid_settings -> {:error, :settings_unavailable}
    end
  end

  # A database outage may make Settings.get_settings/0 return an unpersisted
  # AppSettings struct populated from environment defaults. Durable policy
  # identity must never be minted from that volatile fallback: the run itself
  # could persist after a transient recovery while its route source never did.
  defp persisted_settings(%IexCode.Settings.AppSettings{__meta__: %{state: :built}}),
    do: {:error, :settings_unavailable}

  defp persisted_settings(%IexCode.Settings.AppSettings{__meta__: %{state: :deleted}}),
    do: {:error, :settings_unavailable}

  defp persisted_settings(_settings), do: :ok

  defp fetch_project(project_id) do
    {:ok, Projects.get_project!(project_id)}
  rescue
    _error -> {:error, :project_not_found}
  end

  defp fetch_session(session_id) do
    case Sessions.get_session(session_id) do
      nil -> {:error, :session_not_found}
      session -> {:ok, session}
    end
  rescue
    _error -> {:error, :session_not_found}
  end

  defp resolve_policy(scope, context) do
    overrides =
      context
      |> value(:overrides)
      |> Kernel.||(%{})
      |> drop_router_overrides()

    if is_map(overrides) do
      Policy.from_settings(scope.settings, scope.session, overrides)
    else
      {:error, :invalid_execution_overrides}
    end
  end

  defp validate_intent(%Intent{} = intent) do
    valid_shape? =
      intent.kind in [
        :prompt,
        :run,
        :swarm,
        :goal,
        :research,
        :research_picker,
        :research_attachment,
        :navigate,
        :help
      ] and
        intent.durability in [:interactive, :durable, :none] and
        intent.mode in [:single, :swarm, :research, :navigation, :help] and
        is_boolean(intent.draft?) and is_binary(intent.source) and
        byte_size(intent.source) in 1..100

    objective_required? = intent.kind in [:prompt, :run, :swarm, :goal, :research]

    cond do
      not valid_shape? ->
        {:error, :invalid_execution_intent}

      not valid_intent_semantics?(intent) ->
        {:error, :invalid_execution_intent}

      objective_required? and not valid_objective?(intent.objective) ->
        {:error, :invalid_execution_objective}

      intent.kind == :research_attachment and
          (not is_integer(intent.attachment_id) or intent.attachment_id <= 0) ->
        {:error, :invalid_research_attachment_id}

      true ->
        :ok
    end
  end

  defp dispatch_intent(%Intent{kind: :help} = intent, _scope, _policy, _context) do
    action = {:help, CommandParser.supported_commands()}
    {:ok, action_result(intent, action)}
  end

  defp dispatch_intent(
         %Intent{kind: :navigate, objective: target} = intent,
         _scope,
         _policy,
         _context
       ) do
    if target == "kanban",
      do: {:ok, action_result(intent, {:navigate, target})},
      else: {:error, :invalid_navigation_target}
  end

  defp dispatch_intent(%Intent{kind: :research_picker} = intent, _scope, _policy, _context) do
    {:ok, action_result(intent, {:research_picker, %{}})}
  end

  defp dispatch_intent(
         %Intent{kind: :research_attachment, attachment_id: attachment_id} = intent,
         scope,
         _policy,
         _context
       ) do
    case ResearchResults.context_attachment(attachment_id, scope.session.id) do
      {:ok, _verified_attachment} ->
        {:ok, action_result(intent, {:research_attachment, attachment_id})}

      {:error, reason} ->
        {:error, {:research_attachment_unavailable, reason}}
    end
  end

  defp dispatch_intent(
         %Intent{kind: :prompt, raw_command: command} = intent,
         scope,
         policy,
         context
       )
       when command in ["/chat", "/ask"] do
    interactive_result(intent, scope, policy, context)
  end

  defp dispatch_intent(%Intent{kind: :prompt} = intent, scope, policy, context) do
    cond do
      intent.durability == :durable ->
        dispatch_background_prompt(intent, scope, policy, context)

      intent.durability == :interactive and policy["dispatch_mode"] == "interactive" ->
        interactive_result(intent, scope, policy, context)

      intent.durability == :interactive ->
        dispatch_background_prompt(intent, scope, policy, context)

      true ->
        {:error, :invalid_prompt_durability}
    end
  end

  defp dispatch_intent(%Intent{kind: :run} = intent, scope, policy, context) do
    enqueue_coding(intent, scope, policy, context, "coding_agent", "single", false)
  end

  defp dispatch_intent(%Intent{kind: :swarm} = intent, scope, policy, context) do
    enqueue_coding(intent, scope, policy, context, "coding_swarm", "swarm", false)
  end

  defp dispatch_intent(%Intent{kind: :goal} = intent, scope, policy, context) do
    draft? = intent.draft? or policy["goal_auto_start"] == false
    enqueue_coding(intent, scope, policy, context, "coding_swarm", "swarm", draft?)
  end

  defp dispatch_intent(%Intent{kind: :research} = intent, scope, policy, context) do
    enqueue_research(intent, scope, policy, context)
  end

  defp dispatch_intent(_intent, _scope, _policy, _context),
    do: {:error, :unsupported_execution_intent}

  defp dispatch_background_prompt(intent, scope, policy, context) do
    case policy["run_mode"] do
      "single" ->
        enqueue_coding(intent, scope, policy, context, "coding_agent", "single", false)

      "swarm" ->
        enqueue_coding(intent, scope, policy, context, "coding_swarm", "swarm", false)

      "dag" ->
        enqueue_default_dag(intent, scope, policy, context)

      "research" ->
        enqueue_research(
          %Intent{intent | kind: :research, mode: :research},
          scope,
          policy,
          context
        )

      mode ->
        {:error, {:unsupported_background_run_mode, mode}}
    end
  end

  defp enqueue_default_dag(intent, scope, policy, context) do
    with {:ok, request_key} <- request_key(context),
         {:ok, metadata} <- base_metadata(intent, policy, context),
         attrs <-
           run_attrs(
             intent,
             scope,
             policy,
             request_key,
             Map.put(metadata, "dag_template", "ordinary_background_v1"),
             "analysis",
             "workflow"
           ),
         existing <- Runs.get_run_by_request_key(scope.session.id, request_key),
         {:ok, run} <- enqueue_dag(attrs, DagTemplate.steps(), context) do
      finish_durable_result(intent, run, request_key, existing, false, scope)
    end
  end

  defp enqueue_dag(attrs, steps, context) do
    cond do
      value(context, :wake_dispatcher) == false -> RunDispatcher.persist_dag(attrs, steps)
      is_nil(value(context, :dispatcher)) -> RunDispatcher.enqueue_dag(attrs, steps)
      true -> RunDispatcher.enqueue_dag(attrs, steps, value(context, :dispatcher))
    end
  end

  defp interactive_result(intent, scope, policy, _context) do
    opts = [
      allowed_tools: policy["allowed_tools"],
      model_provider: policy["model_provider"],
      model_name: policy["model_name"],
      temperature: policy["temperature"],
      max_tokens: policy["max_tokens"]
    ]

    result =
      intent
      |> action_result({:interactive, intent.objective, opts})
      |> Map.put(:execution_policy, policy)
      |> Map.put(:session_id, scope.session.id)

    {:ok, result}
  end

  defp enqueue_coding(intent, scope, policy, context, kind, mode, draft?) do
    with {:ok, request_key} <- request_key(context),
         {:ok, metadata} <- coding_metadata(intent, policy, context, draft?, request_key),
         attrs <-
           intent
           |> run_attrs(scope, policy, request_key, metadata, kind, mode)
           |> maybe_put_goal_objective(intent, metadata),
         existing <- Runs.get_run_by_request_key(scope.session.id, request_key),
         {:ok, run} <- enqueue_or_draft(attrs, draft?, context) do
      finish_durable_result(intent, run, request_key, existing, draft?, scope)
    end
  end

  defp enqueue_or_draft(attrs, true, _context), do: RunDispatcher.create_draft(attrs)

  defp enqueue_or_draft(attrs, false, context) do
    cond do
      value(context, :wake_dispatcher) == false -> RunDispatcher.persist(attrs)
      is_nil(value(context, :dispatcher)) -> RunDispatcher.enqueue(attrs)
      true -> RunDispatcher.enqueue(attrs, value(context, :dispatcher))
    end
  end

  defp enqueue_research(intent, scope, policy, context) do
    with {:ok, request_key} <- request_key(context),
         {:ok, metadata} <- base_metadata(intent, policy, context),
         request <- research_request(intent, scope.settings, context),
         existing <- Runs.get_run_by_request_key(scope.session.id, request_key),
         launch_context <- research_context(scope, policy, context, request_key, metadata),
         {:ok, run} <- ResearchLaunch.enqueue(launch_context, request) do
      finish_durable_result(intent, run, request_key, existing, false, scope)
    end
  end

  defp finish_durable_result(intent, run, request_key, existing, draft?, scope) do
    case Sessions.ensure_run_user_message(run) do
      {:ok, message, disposition} ->
        if disposition == :created do
          Phoenix.PubSub.broadcast(
            IexCode.PubSub,
            "session:#{scope.session.id}",
            {:message_created, message}
          )
        end

        action = if draft?, do: {:draft, run}, else: {:run, run}

        {:ok,
         %{
           action: action,
           intent: intent,
           request_key: request_key,
           run: run,
           replayed?: not is_nil(existing) or disposition == :existing,
           message: message
         }}

      {:error, reason} ->
        {:error, {:submission_message_persistence_failed, reason}}
    end
  end

  defp run_attrs(intent, scope, policy, request_key, metadata, kind, mode) do
    %{
      project_id: scope.project.id,
      session_id: scope.session.id,
      objective: intent.objective,
      kind: kind,
      mode: mode,
      priority: policy["run_priority"],
      max_attempts: policy["run_max_attempts"],
      token_budget: policy["run_token_budget"],
      cost_budget_cents: policy["run_cost_budget_cents"],
      time_budget_ms: minutes_to_ms(policy["run_time_budget_minutes"]),
      request_key: request_key,
      metadata: metadata
    }
  end

  defp coding_metadata(intent, policy, context, draft?, request_key) do
    with {:ok, metadata} <- base_metadata(intent, policy, context) do
      if intent.kind == :goal do
        title = goal_title(intent, context)
        description = goal_description(intent, context)

        {:ok,
         metadata
         |> Map.put("source", "autonomous_goal")
         |> Map.put("goal_title", title)
         |> Map.put("goal_description", description)
         |> Map.put("goal_request_id", request_key)
         |> Map.put("goal_auto_start", not draft?)}
      else
        {:ok, metadata}
      end
    end
  end

  defp base_metadata(intent, policy, context) do
    case value(context, :metadata) do
      nil ->
        {:ok, put_intent_metadata(%{}, intent, policy)}

      metadata when is_map(metadata) ->
        {:ok, metadata |> scrub_metadata() |> put_intent_metadata(intent, policy)}

      _metadata ->
        {:error, :invalid_execution_metadata}
    end
  end

  defp put_intent_metadata(metadata, intent, policy) do
    intent_snapshot = %{
      "kind" => Atom.to_string(intent.kind),
      "durability" => Atom.to_string(intent.durability),
      "mode" => Atom.to_string(intent.mode),
      "source" => intent.source,
      "raw_command" => intent.raw_command
    }

    metadata
    |> Map.put("source", intent.source)
    |> Map.put("intent", intent_snapshot)
    |> Map.put("execution_policy", policy)
    |> Map.put("allowed_tools", policy["allowed_tools"])
  end

  defp scrub_metadata(metadata) when is_map(metadata) do
    Map.new(metadata, fn {key, val} -> {key, scrub_metadata_value(val)} end)
    |> Enum.reject(fn {key, _value} -> secret_metadata_key?(key) end)
    |> Map.new()
  end

  defp scrub_metadata_value(value) when is_map(value), do: scrub_metadata(value)

  defp scrub_metadata_value(value) when is_list(value),
    do: Enum.map(value, &scrub_metadata_value/1)

  defp scrub_metadata_value(value), do: value

  defp secret_metadata_key?(key) do
    normalized = key |> to_string() |> String.downcase()
    Enum.any?(@metadata_secret_fragments, &String.contains?(normalized, &1))
  end

  defp research_request(intent, settings, context) do
    research = value(context, :research) || %{}

    %{
      objective: intent.objective,
      level: intent.level || value(research, :level) || value(settings, :research_level),
      ranked_providers:
        value(research, :ranked_providers) || value(context, :ranked_providers) ||
          ResearchLaunch.ready_ranked_providers(settings),
      grounded_providers:
        value(research, :grounded_providers) || value(context, :grounded_providers) || [],
      max_sources:
        value(research, :max_sources) || value(context, :max_sources) ||
          value(settings, :research_max_sources),
      fetch_parallelism:
        value(research, :fetch_parallelism) || value(context, :fetch_parallelism) ||
          value(settings, :research_parallelism),
      require_conflict_audit:
        first_present([
          value(research, :require_conflict_audit),
          value(context, :require_conflict_audit),
          value(settings, :research_require_conflict_audit),
          true
        ]),
      attachments:
        value(research, :attachments) || value(context, :attachment_ids) ||
          value(context, :attachments) || []
    }
  end

  defp research_context(scope, policy, context, request_key, metadata) do
    research = value(context, :research) || %{}

    %{
      project_id: scope.project.id,
      session_id: scope.session.id,
      settings: scope.settings,
      wake_dispatcher: value(context, :wake_dispatcher),
      request_key: request_key,
      metadata: metadata,
      priority: policy["run_priority"],
      token_budget:
        first_present([
          value(research, :token_budget),
          value(scope.settings, :research_max_tokens),
          policy["run_token_budget"]
        ]),
      cost_budget_cents:
        first_present([
          value(research, :cost_budget_cents),
          value(scope.settings, :research_max_cost_cents),
          policy["run_cost_budget_cents"]
        ]),
      time_budget_ms:
        first_present([
          minutes_to_ms(value(research, :time_budget_minutes)),
          minutes_to_ms(value(scope.settings, :research_time_budget_minutes)),
          minutes_to_ms(policy["run_time_budget_minutes"])
        ])
    }
  end

  defp request_key(context) do
    candidate = value(context, :request_key) || Ecto.UUID.generate()

    if valid_request_key?(candidate),
      do: {:ok, candidate},
      else: {:error, :invalid_request_key}
  end

  defp valid_request_key?(value) when is_binary(value) do
    byte_size(value) in 1..@max_request_key_bytes and String.valid?(value) and
      String.printable?(value) and not Regex.match?(~r/\s/u, value)
  end

  defp valid_request_key?(_value), do: false

  defp goal_title(intent, context) do
    overrides = value(context, :overrides) || %{}

    case value(context, :goal_title) || value(overrides, :goal_title) do
      title when is_binary(title) and title != "" ->
        title |> String.trim() |> String.slice(0, 240)

      _other ->
        intent.objective |> first_line() |> String.slice(0, 240)
    end
  end

  defp goal_description(intent, context) do
    overrides = value(context, :overrides) || %{}

    case value(context, :goal_description) || value(overrides, :goal_description) do
      description when is_binary(description) ->
        description |> String.trim() |> String.slice(0, 100_000)

      _other ->
        inferred_goal_description(intent.objective)
    end
  end

  defp first_line(value), do: value |> String.split(~r/\R/u, parts: 2) |> List.first()

  defp inferred_goal_description(value) do
    case String.split(value, ~r/\R/u, parts: 2) do
      [_title, description] -> String.trim(description)
      [_title] -> ""
    end
  end

  defp maybe_put_goal_objective(attrs, %Intent{kind: :goal}, metadata) do
    title = metadata["goal_title"]
    description = metadata["goal_description"]

    objective =
      if description == "",
        do: title,
        else: "#{title}\n\nDetailed instructions and acceptance criteria:\n#{description}"

    Map.put(attrs, :objective, objective)
  end

  defp maybe_put_goal_objective(attrs, _intent, _metadata), do: attrs

  defp action_result(intent, action) do
    %{action: action, intent: intent, request_key: nil, run: nil, replayed?: false, message: nil}
  end

  defp valid_objective?(objective) when is_binary(objective),
    do: byte_size(String.trim(objective)) in 1..100_000 and String.valid?(objective)

  defp valid_objective?(_objective), do: false

  defp valid_intent_semantics?(%Intent{kind: :prompt, mode: :single, durability: durability}),
    do: durability in [:interactive, :durable]

  defp valid_intent_semantics?(%Intent{kind: :run, mode: :single, durability: :durable}),
    do: true

  defp valid_intent_semantics?(%Intent{kind: kind, mode: :swarm, durability: :durable})
       when kind in [:swarm, :goal],
       do: true

  defp valid_intent_semantics?(%Intent{kind: :research, mode: :research, durability: :durable}),
    do: true

  defp valid_intent_semantics?(%Intent{kind: kind, mode: :research, durability: :none})
       when kind in [:research_picker, :research_attachment],
       do: true

  defp valid_intent_semantics?(%Intent{kind: :navigate, mode: :navigation, durability: :none}),
    do: true

  defp valid_intent_semantics?(%Intent{kind: :help, mode: :help, durability: :none}), do: true
  defp valid_intent_semantics?(_intent), do: false

  defp minutes_to_ms(value) when is_integer(value) and value > 0, do: value * 60_000
  defp minutes_to_ms(_value), do: nil

  defp id(%{id: id}) when is_binary(id), do: id
  defp id(id) when is_binary(id), do: id
  defp id(_id), do: nil

  defp value(nil, _key), do: nil

  defp value(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key)))
  end

  defp value(_map, _key), do: nil

  defp first_present(values), do: Enum.find(values, &(not is_nil(&1)))

  defp drop_router_overrides(overrides) when is_map(overrides) do
    Map.drop(overrides, [:goal_title, :goal_description, "goal_title", "goal_description"])
  end
end
