defmodule IexCode.Execution.PolicyTest do
  use ExUnit.Case, async: true

  alias IexCode.Execution.{ModelRoute, Policy, PolicyError}

  @core_tools ~w(
    read_file
    read_output_artifact
    write_file
    patch_file
    multi_patch
    list_dir
    grep_search
    run_tests
    run_command
    git_status
    git_diff
    git_stage
    git_commit
    git_generate_commit
  )

  test "empty settings produce the normalized, secret-free v1 policy" do
    assert {:ok, policy} = Policy.from_settings(%{})

    assert policy == %{
             "version" => 1,
             "dispatch_mode" => "background",
             "run_mode" => "swarm",
             "run_priority" => "normal",
             "run_max_attempts" => 3,
             "run_token_budget" => nil,
             "run_cost_budget_cents" => nil,
             "run_time_budget_minutes" => nil,
             "goal_auto_start" => true,
             "agent_max_turns" => 8,
             "swarm_agent_count" => 4,
             "swarm_max_retries" => 3,
             "allowed_tools" => @core_tools ++ ["ast_search"],
             "model_provider" => "openai",
             "model_name" => "deepseek-v4-pro",
             "model_route_sha256" =>
               "9a272b777943c8ecd1f529ffcb5d3f6e5f8f582ec7ace161cd7aa28f17a7dd7f",
             "temperature" => 0.2,
             "max_tokens" => 4_096
           }
  end

  test "consumes atom-keyed AppSettings-shaped values" do
    settings = %{
      default_dispatch_mode: "interactive",
      default_run_mode: "research",
      default_run_priority: "critical",
      default_run_max_attempts: 7,
      default_run_token_budget: 50_000,
      default_run_cost_budget_cents: 900,
      default_run_time_budget_minutes: 45,
      goal_auto_start: false,
      agent_max_turns: 15,
      swarm_agent_count: 12,
      swarm_max_retries: 6,
      default_tools: %{ast_search: false, web_search: true},
      default_model_provider: "anthropic",
      default_model: "claude-policy-model",
      temperature: 0.65,
      max_tokens: 16_384,
      anthropic_api_key: "must-not-leak",
      anthropic_base_url: "https://must-not-leak.example"
    }

    assert {:ok, policy} = Policy.from_settings(settings)
    assert policy["dispatch_mode"] == "interactive"
    assert policy["run_mode"] == "research"
    assert policy["run_priority"] == "critical"
    assert policy["run_max_attempts"] == 7
    assert policy["run_token_budget"] == 50_000
    assert policy["run_cost_budget_cents"] == 900
    assert policy["run_time_budget_minutes"] == 45
    assert policy["goal_auto_start"] == false
    assert policy["agent_max_turns"] == 15
    assert policy["swarm_agent_count"] == 12
    assert policy["swarm_max_retries"] == 6
    assert policy["model_provider"] == "anthropic"
    assert policy["model_name"] == "claude-policy-model"
    assert policy["temperature"] == 0.65
    assert policy["max_tokens"] == 16_384
    assert policy["allowed_tools"] == @core_tools ++ ["web_search", "fetch_url"]
    refute inspect(policy) =~ "must-not-leak"
  end

  test "route digest ignores credentials but changes with the effective endpoint" do
    settings = %{
      default_model_provider: "openai",
      default_model: "gpt-route-test",
      openai_api_key: "first-secret",
      openai_base_url: "https://one.example/v1"
    }

    assert {:ok, first} = Policy.from_settings(settings)

    rotated_settings = %{settings | openai_api_key: "rotated-secret"}
    assert {:ok, rotated} = Policy.from_settings(rotated_settings)

    assert first["model_route_sha256"] == rotated["model_route_sha256"]

    assert {:ok, %{"api_key" => "rotated-secret"}} =
             ModelRoute.resolve(first, rotated_settings)

    assert {:ok, changed} =
             Policy.from_settings(%{settings | openai_base_url: "https://two.example/v1"})

    refute first["model_route_sha256"] == changed["model_route_sha256"]
    refute inspect(first) =~ "first-secret"
    refute inspect(first) =~ "one.example"
  end

  test "route resolution honors an explicit provider for opaque model identifiers" do
    settings = %{
      default_model_provider: "openai",
      default_model: "claude-proxy-alias",
      openai_api_key: "proxy-secret",
      openai_base_url: "https://proxy.example/v1",
      anthropic_api_key: "unused-secret",
      anthropic_base_url: "https://anthropic.example"
    }

    assert {:ok, policy} = Policy.from_settings(settings)

    assert {:ok,
            %{
              "provider" => "openai",
              "model" => "claude-proxy-alias",
              "api_key" => "proxy-secret",
              "base_url" => "https://proxy.example/v1"
            }} = ModelRoute.resolve(policy, settings)
  end

  test "runtime route resolution rejects volatile settings" do
    assert {:ok, policy} = Policy.from_settings(%{})

    assert {:error, :settings_unavailable} =
             ModelRoute.resolve(policy, %IexCode.Settings.AppSettings{})
  end

  test "supports string-keyed maps and session model precedence" do
    settings = %{
      "default_model_provider" => "anthropic",
      "default_model" => "settings-model",
      "temperature" => "0.4",
      "max_tokens" => "8000"
    }

    session = %{
      "model_provider" => "openai",
      "model_name" => "session-model",
      "temperature" => 0.75,
      "openai_api_key" => "session-secret"
    }

    assert {:ok, policy} = Policy.from_settings(settings, session)
    assert policy["model_provider"] == "openai"
    assert policy["model_name"] == "session-model"
    assert policy["temperature"] == 0.75
    assert policy["max_tokens"] == 8_000
    refute inspect(policy) =~ "session-secret"
  end

  test "valid overrides accept canonical and settings-shaped aliases" do
    overrides = %{
      "default_dispatch_mode" => "interactive",
      default_run_mode: "dag",
      priority: "high",
      max_attempts: "5",
      token_budget: "25000",
      cost_budget_cents: 700,
      time_budget_minutes: "60",
      goal_auto_start: "false",
      agent_max_turns: "20",
      swarm_agent_count: "32",
      swarm_max_retries: "0",
      model_provider: "anthropic",
      model_name: " override-model ",
      temperature: "1.25",
      max_tokens: "128000",
      default_tools: %{"ast_search" => "false", "web_search" => "true"}
    }

    assert {:ok, policy} = Policy.from_settings(%{}, nil, overrides)
    assert policy["dispatch_mode"] == "interactive"
    assert policy["run_mode"] == "dag"
    assert policy["run_priority"] == "high"
    assert policy["run_max_attempts"] == 5
    assert policy["run_token_budget"] == 25_000
    assert policy["run_cost_budget_cents"] == 700
    assert policy["run_time_budget_minutes"] == 60
    assert policy["goal_auto_start"] == false
    assert policy["agent_max_turns"] == 20
    assert policy["swarm_agent_count"] == 32
    assert policy["swarm_max_retries"] == 0
    assert policy["model_provider"] == "anthropic"
    assert policy["model_name"] == "override-model"
    assert policy["temperature"] == 1.25
    assert policy["max_tokens"] == 128_000
    assert policy["allowed_tools"] == @core_tools ++ ["web_search", "fetch_url"]
  end

  test "model identifiers are bounded consistently at 240 bytes" do
    ascii_boundary = String.duplicate("m", 240)
    multibyte_boundary = String.duplicate("é", 120)

    for model <- [ascii_boundary, multibyte_boundary] do
      assert {:ok, policy} = Policy.from_settings(%{}, nil, %{model_name: model})
      assert policy["model_name"] == model
      assert byte_size(policy["model_name"]) == 240
    end

    for model <- [String.duplicate("m", 241), multibyte_boundary <> "a"] do
      assert {:error, %PolicyError{code: :invalid_override, field: "model_name"}} =
               Policy.from_settings(%{}, nil, %{model_name: model})
    end
  end

  test "explicit allowed tools replace expanded defaults in canonical order" do
    assert {:ok, policy} =
             Policy.from_settings(%{}, nil, %{
               allowed_tools: ["fetch_url", "read_file", "web_search"]
             })

    assert policy["allowed_tools"] == ["read_file", "web_search", "fetch_url"]
  end

  test "explicit nil or blank optional budgets clear inherited limits" do
    settings = %{
      default_run_token_budget: 100,
      default_run_cost_budget_cents: 200,
      default_run_time_budget_minutes: 30
    }

    assert {:ok, policy} =
             Policy.from_settings(settings, nil, %{
               token_budget: nil,
               cost_budget_cents: "",
               time_budget_minutes: nil
             })

    assert policy["run_token_budget"] == nil
    assert policy["run_cost_budget_cents"] == nil
    assert policy["run_time_budget_minutes"] == nil
  end

  test "invalid stored values fall back to safe defaults" do
    invalid_settings = %{
      default_dispatch_mode: "surprise",
      default_run_mode: "shell",
      default_run_priority: "urgent",
      default_run_max_attempts: 999,
      default_run_token_budget: -1,
      goal_auto_start: "maybe",
      agent_max_turns: 0,
      swarm_agent_count: 1,
      swarm_max_retries: 99,
      default_tools: %{"ast_search" => "maybe", "unknown" => true},
      default_model_provider: "unknown",
      default_model: "",
      temperature: :hot,
      max_tokens: 0
    }

    assert {:ok, policy} = Policy.from_settings(invalid_settings)
    assert policy["dispatch_mode"] == "background"
    assert policy["run_mode"] == "swarm"
    assert policy["run_priority"] == "normal"
    assert policy["run_max_attempts"] == 3
    assert policy["run_token_budget"] == nil
    assert policy["goal_auto_start"] == true
    assert policy["agent_max_turns"] == 8
    assert policy["swarm_agent_count"] == 4
    assert policy["swarm_max_retries"] == 3
    assert policy["model_provider"] == "openai"
    assert policy["model_name"] == "deepseek-v4-pro"
    assert policy["temperature"] == 0.2
    assert policy["max_tokens"] == 4_096
  end

  test "invalid explicit overrides fail closed with their canonical field" do
    cases = [
      {%{dispatch_mode: "automatic"}, "dispatch_mode"},
      {%{run_mode: "code"}, "run_mode"},
      {%{priority: "urgent"}, "run_priority"},
      {%{max_attempts: 0}, "run_max_attempts"},
      {%{token_budget: -1}, "run_token_budget"},
      {%{cost_budget_cents: "1.5"}, "run_cost_budget_cents"},
      {%{time_budget_minutes: 10_081}, "run_time_budget_minutes"},
      {%{goal_auto_start: "maybe"}, "goal_auto_start"},
      {%{agent_max_turns: 21}, "agent_max_turns"},
      {%{swarm_agent_count: 3}, "swarm_agent_count"},
      {%{swarm_max_retries: 11}, "swarm_max_retries"},
      {%{model_provider: "gemini"}, "model_provider"},
      {%{model_name: ""}, "model_name"},
      {%{model_name: <<255, 254>>}, "model_name"},
      {%{temperature: 2.1}, "temperature"},
      {%{temperature: <<255>>}, "temperature"},
      {%{max_tokens: 0}, "max_tokens"},
      {%{default_tools: %{"unknown" => true}}, "default_tools"},
      {%{allowed_tools: ["read_file", "unknown"]}, "allowed_tools"},
      {%{allowed_tools: ["read_file", "read_file"]}, "allowed_tools"}
    ]

    for {overrides, field} <- cases do
      assert {:error, %PolicyError{code: :invalid_override, field: ^field, message: message}} =
               Policy.from_settings(%{}, nil, overrides)

      assert message =~ field
    end
  end

  test "unknown and duplicate aliases fail closed" do
    assert {:error,
            %PolicyError{
              code: :unsupported_override,
              field: "api_key",
              value: :redacted
            }} = Policy.from_settings(%{}, nil, %{api_key: "secret"})

    {:error, credential_error} = Policy.from_settings(%{}, nil, %{api_key: "secret"})
    refute inspect(credential_error) =~ "secret"

    assert {:error, %PolicyError{code: :invalid_override, field: "run_priority"}} =
             Policy.from_settings(%{}, nil, %{
               "default_run_priority" => "low",
               priority: "high"
             })
  end

  test "output is flat, string-keyed, deterministic, and credential-free" do
    settings = %{
      openai_api_key: "openai-secret",
      anthropic_api_key: "anthropic-secret",
      openai_base_url: "https://secret.example/v1",
      search_providers: %{"tavily" => %{"api_key" => "search-secret"}}
    }

    assert {:ok, first} = Policy.from_settings(settings)
    assert {:ok, second} = Policy.from_settings(settings)
    assert first == second
    assert Enum.all?(Map.keys(first), &is_binary/1)
    refute Enum.any?(Map.values(first), &is_map/1)

    rendered = inspect(first)
    refute rendered =~ "openai-secret"
    refute rendered =~ "anthropic-secret"
    refute rendered =~ "secret.example"
    refute rendered =~ "search-secret"
  end

  test "non-map inputs are rejected without raising" do
    for {settings, session, overrides} <- [
          {nil, nil, %{}},
          {%{}, [], %{}},
          {%{}, nil, []}
        ] do
      assert {:error, %PolicyError{code: :invalid_override, field: "policy"}} =
               Policy.from_settings(settings, session, overrides)
    end
  end
end
