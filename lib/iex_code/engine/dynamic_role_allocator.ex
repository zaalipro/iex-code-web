defmodule IexCode.Engine.DynamicRoleAllocator do
  @moduledoc """
  Dynamic Role Allocation and Heuristic Task Complexity Engine.
  Evaluates task scope, risk, intent, and research context to allocate
  appropriately sized agent rosters (Tier 1 to Tier 4) with calibrated model capabilities.
  """

  alias IexCode.Swarm.RoleSpec

  @w_scope 0.35
  @w_risk 0.30
  @w_intent 0.20
  @w_research 0.15

  defp risk_patterns do
    [
      auth: ~r/(auth|login|password|session|oauth|token|credential|jwt)/i,
      crypto: ~r/(crypto|hash|cipher|encrypt|decrypt|signature|rsa|ecdsa|hmac)/i,
      security: ~r/(security|permission|policy|privilege|admin|role|rbac|access_control)/i,
      sandbox: ~r/(sandbox|isolation|container|jail|restricted|safe_mode)/i,
      data_loss: ~r/(drop|delete|truncate|rollback|migration|remove_all|purge|vps)/i,
      execution: ~r/(shell|exec|cmd|system|os\.cmd|eval|dangerous)/i
    ]
  end

  @doc """
  Assesses task complexity across scope, risk, intent, and research context.
  Returns composite score in [0.0, 100.0].
  """
  @spec assess_task_complexity(String.t() | nil, list() | nil, map()) :: float()
  def assess_task_complexity(prompt, target_files, context \\ %{}) do
    breakdown = assess_task_complexity_breakdown(prompt, target_files, context)
    breakdown.composite
  end

  @doc """
  Calculates the detailed breakdown of the 4 complexity dimensions.
  """
  @spec assess_task_complexity_breakdown(String.t() | nil, list() | nil, map()) :: map()
  def assess_task_complexity_breakdown(prompt, target_files, context \\ %{}) do
    prompt_str = to_string(prompt || "")
    files = normalize_file_list(target_files)
    ctx = context || %{}

    s_scope = calculate_scope_score(files)
    s_risk = calculate_risk_score(prompt_str, files)
    s_intent = calculate_intent_score(prompt_str)
    s_research = calculate_research_score(ctx)

    composite =
      @w_scope * s_scope +
        @w_risk * s_risk +
        @w_intent * s_intent +
        @w_research * s_research

    clamped = composite |> max(0.0) |> min(100.0) |> Float.round(2)

    %{
      composite: clamped,
      scope: s_scope,
      risk: s_risk,
      intent: s_intent,
      research: s_research
    }
  end

  # ============================================================================
  # ROSTER ALLOCATION
  # ============================================================================

  @doc """
  Allocates a swarm roster matching the task complexity score (or calculated from prompt).
  Tiers:
  - Tier 1 (0..24): :trivial, 2 agents (Coder, Auditor)
  - Tier 2 (25..54): :standard, 4 agents (Explorer, Architect, Coder, Auditor)
  - Tier 3 (55..79): :refactor, 6 agents (Explorer x2, Architect, Coder x2, Auditor)
  - Tier 4 (80..100): :critical, 8-12 agents (Explorer x3, Architect, Coder x3, SecurityAuditor, Auditor, Verifier, Synthesizer)
  """
  @spec allocate_roster(number() | map() | String.t(), keyword() | list(), map()) ::
          [RoleSpec.t()] | map()
  def allocate_roster(score_or_prompt, opts_or_targets \\ [], maybe_context \\ %{})

  # Overload when called with (prompt, target_files, context)
  def allocate_roster(prompt, target_files, context)
      when is_binary(prompt) and is_list(target_files) do
    score = assess_task_complexity(prompt, target_files, context)
    allocate_roster(score, [])
  end

  def allocate_roster(score_or_map, opts, _context) do
    score = extract_score(score_or_map)
    format = Keyword.get(opts, :format, :roster)
    tier_info = classify_tier(score)

    agents = build_tier_agents(tier_info.tier, opts)

    case format do
      :manifest ->
        %{
          tier: tier_info.tier,
          classification: tier_info.classification,
          complexity_score: score,
          agent_count: length(agents),
          agents: agents
        }

      _ ->
        agents
    end
  end

  @doc """
  Returns the tier classification and metadata for a given score.
  """
  def classify_tier(score) when is_number(score) do
    cond do
      score < 25.0 ->
        %{tier: 1, classification: :trivial, agent_count: 2}

      score < 55.0 ->
        %{tier: 2, classification: :standard, agent_count: 4}

      score < 80.0 ->
        %{tier: 3, classification: :refactor, agent_count: 6}

      true ->
        %{tier: 4, classification: :critical, agent_count: 11}
    end
  end

  defp build_tier_agents(1, _opts) do
    [
      RoleSpec.new(%{
        role: :coder,
        display_name: "Coder (Haiku)",
        model_provider: "anthropic",
        model_id: "claude-3-5-haiku",
        reasoning_effort: "low",
        temperature: 0.2,
        allowed_tools: [:view_file, :grep_search, :replace_file_content, :write_to_file]
      }),
      RoleSpec.new(%{
        role: :auditor,
        display_name: "Auditor (GPT-4o-mini)",
        model_provider: "openai",
        model_id: "gpt-4o-mini",
        reasoning_effort: "none",
        temperature: 0.2,
        allowed_tools: [:view_file, :grep_search]
      })
    ]
  end

  defp build_tier_agents(2, _opts) do
    [
      RoleSpec.new(%{
        role: :explorer,
        display_name: "Explorer Lead",
        model_provider: "anthropic",
        model_id: "claude-3-7-sonnet",
        reasoning_effort: "medium",
        temperature: 0.3,
        allowed_tools: [:view_file, :grep_search, :list_dir, :find_by_name]
      }),
      RoleSpec.new(%{
        role: :architect,
        display_name: "Architect Lead",
        model_provider: "anthropic",
        model_id: "claude-3-7-sonnet",
        reasoning_effort: "medium",
        temperature: 0.3,
        allowed_tools: [:view_file, :grep_search]
      }),
      RoleSpec.new(%{
        role: :coder,
        display_name: "Coder Agent",
        model_provider: "anthropic",
        model_id: "claude-3-7-sonnet",
        reasoning_effort: "medium",
        temperature: 0.3,
        allowed_tools: [:view_file, :grep_search, :replace_file_content, :write_to_file]
      }),
      RoleSpec.new(%{
        role: :auditor,
        display_name: "Auditor Agent",
        model_provider: "openai",
        model_id: "gpt-4o",
        reasoning_effort: "medium",
        temperature: 0.2,
        allowed_tools: [:view_file, :grep_search]
      })
    ]
  end

  defp build_tier_agents(3, _opts) do
    [
      RoleSpec.new(%{
        role: :explorer,
        display_name: "Explorer Shard 1",
        model_provider: "anthropic",
        model_id: "claude-3-7-sonnet",
        reasoning_effort: "high",
        temperature: 0.2,
        allowed_tools: [:view_file, :grep_search, :list_dir, :find_by_name]
      }),
      RoleSpec.new(%{
        role: :explorer,
        display_name: "Explorer Shard 2",
        model_provider: "openai",
        model_id: "o3-mini",
        reasoning_effort: "high",
        temperature: 0.2,
        allowed_tools: [:view_file, :grep_search, :list_dir, :find_by_name]
      }),
      RoleSpec.new(%{
        role: :architect,
        display_name: "Architect Principal",
        model_provider: "anthropic",
        model_id: "claude-3-7-sonnet",
        reasoning_effort: "high",
        temperature: 0.2,
        allowed_tools: [:view_file, :grep_search]
      }),
      RoleSpec.new(%{
        role: :coder,
        display_name: "Coder Shard 1",
        model_provider: "anthropic",
        model_id: "claude-3-7-sonnet",
        reasoning_effort: "high",
        temperature: 0.2,
        allowed_tools: [:view_file, :grep_search, :replace_file_content, :write_to_file]
      }),
      RoleSpec.new(%{
        role: :coder,
        display_name: "Coder Shard 2",
        model_provider: "openai",
        model_id: "o3-mini",
        reasoning_effort: "high",
        temperature: 0.2,
        allowed_tools: [:view_file, :grep_search, :replace_file_content, :write_to_file]
      }),
      RoleSpec.new(%{
        role: :auditor,
        display_name: "Auditor Lead",
        model_provider: "deepseek",
        model_id: "deepseek-r1",
        reasoning_effort: "high",
        temperature: 0.1,
        allowed_tools: [:view_file, :grep_search]
      })
    ]
  end

  defp build_tier_agents(4, _opts) do
    [
      RoleSpec.new(%{
        role: :explorer,
        display_name: "Explorer Shard 1",
        model_provider: "anthropic",
        model_id: "claude-3-7-sonnet",
        reasoning_effort: "high",
        temperature: 0.2,
        allowed_tools: [:view_file, :grep_search, :list_dir, :find_by_name]
      }),
      RoleSpec.new(%{
        role: :explorer,
        display_name: "Explorer Shard 2",
        model_provider: "openai",
        model_id: "o3-mini",
        reasoning_effort: "high",
        temperature: 0.2,
        allowed_tools: [:view_file, :grep_search, :list_dir, :find_by_name]
      }),
      RoleSpec.new(%{
        role: :explorer,
        display_name: "Explorer Shard 3",
        model_provider: "ollama",
        model_id: "llama3.2:latest",
        reasoning_effort: "medium",
        temperature: 0.2,
        allowed_tools: [:view_file, :grep_search, :list_dir, :find_by_name]
      }),
      RoleSpec.new(%{
        role: :architect,
        display_name: "Chief Architect",
        model_provider: "anthropic",
        model_id: "claude-3-7-sonnet",
        reasoning_effort: "high",
        temperature: 0.1,
        allowed_tools: [:view_file, :grep_search]
      }),
      RoleSpec.new(%{
        role: :coder,
        display_name: "Coder Shard 1",
        model_provider: "anthropic",
        model_id: "claude-3-7-sonnet",
        reasoning_effort: "high",
        temperature: 0.2,
        allowed_tools: [:view_file, :grep_search, :replace_file_content, :write_to_file]
      }),
      RoleSpec.new(%{
        role: :coder,
        display_name: "Coder Shard 2",
        model_provider: "openai",
        model_id: "o3-mini",
        reasoning_effort: "high",
        temperature: 0.2,
        allowed_tools: [:view_file, :grep_search, :replace_file_content, :write_to_file]
      }),
      RoleSpec.new(%{
        role: :coder,
        display_name: "Coder Shard 3",
        model_provider: "ollama",
        model_id: "llama3.2:latest",
        reasoning_effort: "medium",
        temperature: 0.2,
        allowed_tools: [:view_file, :grep_search, :replace_file_content, :write_to_file]
      }),
      RoleSpec.new(%{
        role: :auditor,
        sub_role: :security_auditor,
        display_name: "Security Auditor",
        model_provider: "anthropic",
        model_id: "claude-3-7-sonnet",
        reasoning_effort: "high",
        temperature: 0.0,
        allowed_tools: [:view_file, :grep_search]
      }),
      RoleSpec.new(%{
        role: :auditor,
        display_name: "Adversarial Auditor",
        model_provider: "openai",
        model_id: "o3-mini",
        reasoning_effort: "high",
        temperature: 0.0,
        allowed_tools: [:view_file, :grep_search]
      }),
      RoleSpec.new(%{
        role: :verifier,
        display_name: "Test Runner / Verifier",
        model_provider: "anthropic",
        model_id: "claude-3-5-haiku",
        reasoning_effort: "low",
        temperature: 0.0,
        allowed_tools: [:view_file, :grep_search, :run_command]
      }),
      RoleSpec.new(%{
        role: :synthesizer,
        display_name: "Swarm Consensus Synthesizer",
        model_provider: "anthropic",
        model_id: "claude-3-7-sonnet",
        reasoning_effort: "high",
        temperature: 0.1,
        allowed_tools: [:view_file]
      })
    ]
  end

  # ============================================================================
  # ROLE STATE MACHINE TRANSITIONS
  # ============================================================================

  @valid_transitions %{
    explorer: %{
      unassigned: [:scanning, :idle, :failed],
      scanning: [:synthesizing_context, :idle, :failed],
      synthesizing_context: [:context_ready, :scanning, :failed],
      context_ready: [:idle, :scanning, :failed],
      idle: [:scanning, :unassigned, :failed],
      failed: [:unassigned, :idle]
    },
    architect: %{
      waiting_context: [:designing, :idle, :failed],
      designing: [:spec_published, :redesign_requested, :failed],
      spec_published: [:reviewing_proposals, :designing, :failed],
      reviewing_proposals: [:approved, :redesign_requested, :failed],
      approved: [:idle, :waiting_context],
      redesign_requested: [:designing, :failed],
      idle: [:waiting_context, :designing, :failed],
      failed: [:waiting_context, :idle]
    },
    coder: %{
      waiting_spec: [:generating_patch, :idle, :failed],
      generating_patch: [:self_testing, :proposal_submitted, :failed],
      self_testing: [:proposal_submitted, :generating_patch, :failed],
      proposal_submitted: [:revising, :idle, :failed],
      revising: [:generating_patch, :self_testing, :proposal_submitted, :failed],
      idle: [:waiting_spec, :generating_patch, :failed],
      failed: [:waiting_spec, :idle]
    },
    auditor: %{
      waiting_proposal: [:auditing, :idle, :failed],
      auditing: [:scoring, :verdict_emitted, :failed],
      scoring: [:verdict_emitted, :auditing, :failed],
      verdict_emitted: [:waiting_proposal, :idle, :failed],
      idle: [:waiting_proposal, :auditing, :failed],
      failed: [:waiting_proposal, :idle]
    },
    synthesizer: %{
      collecting_votes: [:matrix_aggregation, :idle, :failed],
      matrix_aggregation: [:gated_merge, :failed],
      gated_merge: [:done, :failed],
      done: [:idle, :collecting_votes],
      idle: [:collecting_votes, :failed],
      failed: [:collecting_votes, :idle]
    },
    verifier: %{
      waiting_run: [:executing_tests, :idle, :failed],
      executing_tests: [:verifying_results, :failed],
      verifying_results: [:passed, :failed_tests, :failed],
      passed: [:idle, :waiting_run],
      failed_tests: [:idle, :waiting_run],
      idle: [:waiting_run, :executing_tests],
      failed: [:waiting_run, :idle]
    }
  }

  @doc """
  Enforces legal state machine transitions for agent roles.
  Supports:
  - transition_state(role, current_state, target_state)
  - transition_state(%RoleSpec{}, target_state)
  - transition_state(current_state, target_state)
  @doc \"""
  Enforces legal state machine transitions for agent roles.
  Supports:
  - transition_state(role, current_state, target_state)
  - transition_state(%RoleSpec{}, target_state)
  - transition_state(agent_map, target_state)
  - transition_state(current_state, target_state)
  """
  @spec transition_state(atom(), atom(), atom()) :: {:ok, atom()} | {:error, term()}
  def transition_state(role, current_state, target_state)
      when is_atom(role) and is_atom(current_state) and is_atom(target_state) do
    role_key = normalize_role_key(role)
    allowed_from_current = get_in(@valid_transitions, [role_key, current_state]) || []

    cond do
      current_state == target_state ->
        {:ok, target_state}

      target_state in allowed_from_current ->
        {:ok, target_state}

      true ->
        {:error, {:invalid_transition, current_state, target_state}}
    end
  end

  @spec transition_state(atom() | map(), atom()) :: {:ok, atom() | map()} | {:error, term()}
  def transition_state(%RoleSpec{} = spec, target_state) when is_atom(target_state) do
    case transition_state(spec.role, spec.state, target_state) do
      {:ok, next_state} ->
        {:ok, %{spec | state: next_state}}

      error ->
        error
    end
  end

  def transition_state(agent_map, target_state)
      when is_map(agent_map) and is_atom(target_state) do
    role = agent_map[:role] || agent_map["role"] || :coder
    current = agent_map[:state] || agent_map["state"] || :idle

    case transition_state(role, current, target_state) do
      {:ok, next_state} ->
        updated =
          cond do
            Map.has_key?(agent_map, :state) -> Map.put(agent_map, :state, next_state)
            Map.has_key?(agent_map, "state") -> Map.put(agent_map, "state", next_state)
            true -> Map.put(agent_map, :state, next_state)
          end

        {:ok, updated}

      error ->
        error
    end
  end

  def transition_state(current_state, target_state)
      when is_atom(current_state) and is_atom(target_state) do
    is_legal? =
      current_state == target_state or
        Enum.any?(@valid_transitions, fn {_role, map} ->
          allowed = Map.get(map, current_state, [])
          target_state in allowed
        end)

    if is_legal? do
      {:ok, target_state}
    else
      {:error, {:invalid_transition, current_state, target_state}}
    end
  end

  defp normalize_role_key(:security_auditor), do: :auditor
  defp normalize_role_key(role) when is_atom(role), do: role
  defp normalize_role_key(_), do: :coder

  # ============================================================================
  # PRIVATE HEURISTIC SCORING HELPERS
  # ============================================================================

  defp calculate_scope_score(files) do
    n = length(files)

    base =
      cond do
        n == 0 -> 100.0
        n == 1 -> 10.0
        n <= 4 -> 35.0
        n <= 9 -> 70.0
        true -> 100.0
      end

    cross_namespace_bonus =
      if has_cross_namespace_boundary?(files) do
        15.0
      else
        0.0
      end

    min(100.0, base + cross_namespace_bonus)
  end

  defp has_cross_namespace_boundary?(files) when length(files) >= 2 do
    dirs =
      files
      |> Enum.map(fn path ->
        parts = Path.split(path)

        # Check second or third directory level (e.g. lib/iex_code/workflows vs lib/iex_code/engine)
        case parts do
          ["lib", "iex_code", dir | _] -> dir
          ["lib", dir | _] -> dir
          [dir | _] -> dir
          _ -> "root"
        end
      end)
      |> Enum.uniq()

    length(dirs) > 1
  end

  defp has_cross_namespace_boundary?(_), do: false

  defp calculate_risk_score(prompt, files) do
    combined = prompt <> " " <> Enum.join(files, " ")

    matches =
      Enum.count(risk_patterns(), fn {_cat, regex} ->
        Regex.run(regex, combined) != nil
      end)

    min(100.0, matches * 30.0)
  end

  defp calculate_intent_score(prompt) do
    cond do
      Regex.run(
        ~r/(from scratch|greenfield|new architecture|new engine|complete rewrite of the system)/i,
        prompt
      ) ->
        100.0

      Regex.run(~r/(refactor|rewrite|restructure|extract module|reorganize|decouple)/i, prompt) ->
        75.0

      Regex.run(~r/(add|create|implement|feature|endpoint|component|extend|build)/i, prompt) ->
        40.0

      Regex.run(~r/(typo|comment|rename|format|whitespace|spelling|minor fix|small fix)/i, prompt) ->
        10.0

      true ->
        40.0
    end
  end

  defp calculate_research_score(context) do
    cond do
      has_disputed_research?(context) ->
        85.0

      has_verified_research?(context) ->
        50.0

      true ->
        0.0
    end
  end

  defp has_disputed_research?(context) do
    disputed =
      Map.get(context, "disputed_claims") ||
        Map.get(context, :disputed_claims) ||
        Map.get(context, "disputed") ||
        Map.get(context, :disputed) ||
        get_nested(context, ["research", "disputed_claims"]) ||
        get_nested(context, ["research", "conflicts"])

    case disputed do
      list when is_list(list) and list != [] -> true
      _ -> false
    end
  end

  defp has_verified_research?(context) do
    verified =
      Map.get(context, "verified_claims") ||
        Map.get(context, :verified_claims) ||
        Map.get(context, "verified") ||
        Map.get(context, :verified) ||
        Map.get(context, "research") ||
        Map.get(context, :research) ||
        get_nested(context, ["research", "verified_claims"])

    case verified do
      list when is_list(list) and list != [] -> true
      map when is_map(map) and map_size(map) > 0 -> true
      _ -> false
    end
  end

  defp get_nested(map, keys) when is_map(map) and is_list(keys) do
    Enum.reduce_while(keys, map, fn key, acc ->
      if is_map(acc) do
        {:cont, Map.get(acc, key) || Map.get(acc, to_string(key))}
      else
        {:halt, nil}
      end
    end)
  end

  defp get_nested(_, _), do: nil

  defp normalize_file_list(nil), do: []
  defp normalize_file_list(files) when is_list(files), do: Enum.map(files, &to_string/1)

  defp normalize_file_list(file) when is_binary(file) do
    file
    |> String.split([",", " ", "\n"], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_file_list(_), do: []

  defp extract_score(num) when is_number(num), do: num * 1.0
  defp extract_score(%{composite: s}) when is_number(s), do: s * 1.0
  defp extract_score(%{"composite" => s}) when is_number(s), do: s * 1.0
  defp extract_score(%{score: s}) when is_number(s), do: s * 1.0
  defp extract_score(%{"score" => s}) when is_number(s), do: s * 1.0
  defp extract_score(_), do: 50.0
end
