defmodule IexCode.Research.DagRuntimeTest do
  use ExUnit.Case, async: true

  alias IexCode.Research.{DagRuntime, Launch}

  @secret "runtime-secret-123"

  test "ranked search resolves current settings, invokes only the fixed provider, and checkpoints" do
    parent = self()

    settings = fn ->
      send(parent, :settings_resolved)

      %{
        "search" => %{
          "providers" => %{
            "brave" => %{"enabled" => true, "api_key" => @secret},
            "tavily" => %{"enabled" => true, "api_key" => "other-secret"}
          }
        }
      }
    end

    search = fn query, opts ->
      send(parent, {:searched, query, opts})

      {:ok,
       %{
         results: [
           %{
             provider: "brave",
             title: "Result #{@secret}",
             url: "https://example.com",
             snippet: String.duplicate("x", 30_000),
             metadata: %{raw: @secret}
           }
         ],
         errors: %{"brave" => {:http_error, 429, @secret}},
         providers: ["brave"]
       }}
    end

    assert {:ok, result} =
             DagRuntime.ranked_search(
               %{"provider" => "brave", "query" => "beam", "max_results" => 1},
               context(parent),
               settings_resolver: settings,
               search_module: search
             )

    assert_receive :settings_resolved
    assert_receive {:searched, "beam", search_opts}
    assert search_opts[:providers] == ["brave"]
    assert Map.keys(search_opts[:config]) == ["brave"]
    refute inspect(result) =~ @secret
    assert result["provider"] == "brave"
    assert result["errors"] == %{"brave" => "provider_http_429"}
    assert String.length(hd(result["results"])["snippet"]) == 1_500

    assert_receive {:provider_effect, "research.ranked_search", descriptor, estimate}
    assert descriptor["query_sha256"] =~ "sha256:"
    refute inspect(descriptor) =~ "beam"
    assert estimate == %{requests: 1, input_tokens: 0, output_tokens: 0, cost_cents: 0}
    assert Jason.encode!(result)
  end

  test "ranked search rejects unknown and disabled providers before an effect" do
    never = fn _query, _opts -> flunk("provider must not be called") end

    assert {:error, :unsupported_provider} =
             DagRuntime.ranked_search(
               %{"provider" => "attacker", "query" => "beam"},
               context(self()),
               settings_resolver: fn -> %{} end,
               search_module: never
             )

    assert {:error, :provider_unavailable} =
             DagRuntime.ranked_search(
               %{"provider" => "brave", "query" => "beam"},
               context(self()),
               settings_resolver: fn ->
                 %{"search" => %{"providers" => %{"brave" => %{"enabled" => false}}}}
               end,
               search_module: never
             )

    refute_receive {:checkpoint, _, _}
  end

  test "runtime params reject credential fields before settings resolution" do
    assert {:error, :secret_in_runtime_params} =
             DagRuntime.ranked_search(
               %{
                 "provider" => "brave",
                 "query" => "beam",
                 "api_key" => @secret
               },
               context(self()),
               settings_resolver: fn -> flunk("secret-bearing params must fail first") end,
               search_module: fn _, _ -> flunk("secret-bearing params must not dispatch") end
             )

    refute_receive {:checkpoint, _, _}
  end

  test "cancellation immediately before the effect prevents provider invocation" do
    cancellation = :atomics.new(1, signed: false)
    checkpoint = fn _payload, _progress -> :ok end

    context = %{
      run: %{session_id: "session"},
      cancelled?: fn -> :atomics.get(cancellation, 1) == 1 end,
      checkpoint_callback: checkpoint,
      provider_effect: fn _operation, _descriptor, _estimate, _callback, _opts ->
        :atomics.put(cancellation, 1, 1)
        {:error, :cancelled}
      end
    }

    assert {:error, :cancelled} =
             DagRuntime.ranked_search(
               %{"provider" => "brave", "query" => "beam"},
               context,
               settings_resolver: ranked_settings(),
               search_module: fn _, _ -> flunk("cancelled effect must not run") end
             )
  end

  test "cancellation immediately after an effect discards its response" do
    cancellation = :atomics.new(1, signed: false)

    search = fn _query, _opts ->
      :atomics.put(cancellation, 1, 1)
      {:ok, %{results: [], errors: %{}, providers: ["brave"]}}
    end

    context = %{
      run: %{session_id: "session"},
      cancelled?: fn -> :atomics.get(cancellation, 1) == 1 end,
      checkpoint_callback: fn _payload, _progress -> :ok end,
      provider_effect: fn _operation, _descriptor, estimate, callback, _opts ->
        case callback.() do
          {:ok, response, usage} ->
            if :atomics.get(cancellation, 1) == 1,
              do: {:error, :external_effect_uncertain},
              else: effect_receipt(response, usage)

          _other ->
            effect_receipt(%{}, estimate)
        end
      end
    }

    assert {:error, :external_effect_uncertain} =
             DagRuntime.ranked_search(
               %{"provider" => "brave", "query" => "beam"},
               context,
               settings_resolver: ranked_settings(),
               search_module: search
             )
  end

  test "grounded search keeps credentials execution-only and returns a stable JSON map" do
    parent = self()

    grounded = fn provider, query, opts ->
      send(parent, {:grounded, provider, query, opts})

      {:ok,
       %{
         answer: "Supported answer",
         provider: :openai_responses,
         citations: [%{url: "https://example.com", title: "Example", start_index: 0}],
         search_calls: [%{id: "call-1", queries: [query], status: "completed"}],
         usage: %{input_tokens: 10, output_tokens: 5},
         metadata: %{}
       }}
    end

    assert {:ok, result} =
             DagRuntime.grounded_search(
               %{
                 "provider" => "openai_responses",
                 "query" => "current release",
                 "max_input_tokens" => 100,
                 "max_cost_cents" => 9,
                 "max_output_tokens" => 2_000
               },
               context(parent),
               settings_resolver: grounded_settings(),
               grounded_search_module: grounded
             )

    assert_receive {:grounded, "openai_responses", "current release", opts}
    assert opts[:api_key] == @secret
    assert opts[:max_output_tokens] == 2_000
    assert is_function(opts[:cancelled?], 0)
    refute Map.has_key?(result, "metadata")
    refute inspect(result) =~ @secret

    assert result["usage"] == %{
             "request_count" => 1,
             "search_calls" => 1,
             "input_tokens" => 10,
             "output_tokens" => 5,
             "cost_cents" => 9
           }

    assert Jason.encode!(result)
  end

  test "ranked search refuses a changed effective route before any effect" do
    parent = self()
    session = routing_session()
    reference = Launch.settings_snapshot_ref(strict_settings(4), session, ["brave"], [])
    runtime_context = research_context(parent, ["brave"], [])

    assert {:ok, result} =
             DagRuntime.ranked_search(
               %{
                 "provider" => "brave",
                 "query" => "stable route",
                 "provider_snapshot_ref" => reference
               },
               runtime_context,
               settings_resolver: fn -> strict_settings(4) end,
               session_resolver: fn "session" -> session end,
               search_module: fn "stable route", _opts ->
                 {:ok, %{results: [], errors: %{}, providers: ["brave"]}}
               end
             )

    assert result["provider"] == "brave"
    assert_receive {:provider_effect, "research.ranked_search", _, _}

    blocked_context =
      put_in(runtime_context.provider_effect, fn _, _, _, _, _ ->
        flunk("changed routing must stop before the effect boundary")
      end)

    assert {:error, :provider_configuration_changed} =
             DagRuntime.ranked_search(
               %{
                 "provider" => "brave",
                 "query" => "changed route",
                 "provider_snapshot_ref" => reference
               },
               blocked_context,
               settings_resolver: fn ->
                 put_in(
                   strict_settings(5),
                   ["search", "providers", "brave", "base_url"],
                   "https://changed.example"
                 )
               end,
               session_resolver: fn "session" -> session end,
               search_module: fn _, _ -> flunk("changed routing must not invoke the provider") end
             )
  end

  test "grounded search refuses a changed effective model route before any effect" do
    parent = self()
    session = routing_session()

    reference =
      Launch.settings_snapshot_ref(strict_settings(4), session, [], ["openai_responses"])

    runtime_context = research_context(parent, [], ["openai_responses"])

    grounded = fn "openai_responses", query, _opts ->
      {:ok,
       %{
         answer: "Answer",
         provider: :openai_responses,
         citations: [],
         search_calls: [%{id: "call-1", queries: [query], status: "completed"}],
         usage: %{input_tokens: 1, output_tokens: 1},
         metadata: %{}
       }}
    end

    params = %{
      "provider" => "openai_responses",
      "query" => "grounded route",
      "max_input_tokens" => 100,
      "max_output_tokens" => 1_000,
      "max_cost_cents" => 10,
      "provider_snapshot_ref" => reference
    }

    assert {:ok, _result} =
             DagRuntime.grounded_search(params, runtime_context,
               settings_resolver: fn -> strict_settings(4) end,
               session_resolver: fn "session" -> session end,
               grounded_search_module: grounded
             )

    assert_receive {:provider_effect, "research.grounded_search", _, _}

    blocked_context =
      put_in(runtime_context.provider_effect, fn _, _, _, _, _ ->
        flunk("changed routing must stop before the effect boundary")
      end)

    assert {:error, :provider_configuration_changed} =
             DagRuntime.grounded_search(params, blocked_context,
               settings_resolver: fn ->
                 put_in(
                   strict_settings(5),
                   ["grounded_providers", "openai_responses", "model"],
                   "gpt-changed"
                 )
               end,
               session_resolver: fn "session" -> session end,
               grounded_search_module: fn _, _, _ ->
                 flunk("changed routing must not invoke the provider")
               end
             )
  end

  test "report synthesis refuses a changed strict session model or endpoint" do
    parent = self()
    session = routing_session()

    reference =
      Launch.settings_snapshot_ref(
        strict_settings(4),
        session,
        ["brave"],
        ["openai_responses"]
      )

    runtime_context = research_context(parent, ["brave"], ["openai_responses"])

    params = %{
      "objective" => "Verify synthesis routing",
      "depth" => "high",
      "sources" => [
        %{
          "url" => "https://example.com",
          "title" => "Evidence",
          "provider" => "brave",
          "snippet" => "bounded evidence"
        }
      ],
      "max_input_tokens" => 2_000,
      "max_output_tokens" => 1_000,
      "provider_snapshot_ref" => reference
    }

    llm = fn _messages, _system, _session, _on_chunk, _opts ->
      {:ok, %{text: "# Verified", usage: %{input_tokens: 1, output_tokens: 1}}}
    end

    assert {:ok, %{"markdown" => "# Verified"}} =
             DagRuntime.synthesize_report(params, runtime_context,
               settings_resolver: fn -> strict_settings(4) end,
               session_resolver: fn "session" -> session end,
               llm_module: llm
             )

    assert_receive {:provider_effect, "research.report_synthesis", _, _}

    blocked_context =
      put_in(runtime_context.provider_effect, fn _, _, _, _, _ ->
        flunk("changed routing must stop before the effect boundary")
      end)

    assert {:error, :provider_configuration_changed} =
             DagRuntime.synthesize_report(params, blocked_context,
               settings_resolver: fn ->
                 put_in(
                   strict_settings(5),
                   ["synthesis_providers", "openai", "base_url"],
                   "https://changed-models.example"
                 )
               end,
               session_resolver: fn "session" -> session end,
               llm_module: fn _, _, _, _, _ ->
                 flunk("changed settings must not call the model")
               end
             )

    assert {:error, :provider_configuration_changed} =
             DagRuntime.synthesize_report(params, blocked_context,
               settings_resolver: fn -> strict_settings(4) end,
               session_resolver: fn "session" -> %{session | model_name: "gpt-next"} end,
               llm_module: fn _, _, _, _, _ -> flunk("changed model must not be called") end
             )
  end

  test "legacy current-settings references remain executable" do
    assert {:ok, _result} =
             DagRuntime.ranked_search(
               %{
                 "provider" => "brave",
                 "query" => "legacy route",
                 "provider_snapshot_ref" => "settings://search-providers/current"
               },
               context(self()),
               settings_resolver: ranked_settings(),
               search_module: fn _, _ ->
                 {:ok, %{results: [], errors: %{}, providers: ["brave"]}}
               end
             )
  end

  test "provider exceptions and checkpoint failures become stable redacted errors" do
    leaking = fn _query, _opts -> raise "upstream echoed #{@secret}" end

    assert {:error, :provider_effect_failed} =
             DagRuntime.ranked_search(
               %{"provider" => "brave", "query" => "beam"},
               context(self()),
               settings_resolver: ranked_settings(),
               search_module: leaking
             )

    broken_context = %{
      run: %{session_id: "session"},
      cancelled?: fn -> false end,
      checkpoint_callback: fn _payload, _progress -> {:error, @secret} end,
      provider_effect: fn _operation, _descriptor, _estimate, _callback, _opts ->
        {:error, :checkpoint_failed}
      end
    }

    assert {:error, :checkpoint_failed} =
             DagRuntime.ranked_search(
               %{"provider" => "brave", "query" => "beam"},
               broken_context,
               settings_resolver: ranked_settings(),
               search_module: fn _, _ -> flunk("failed checkpoint must stop effect") end
             )
  end

  test "source fetching preserves provenance, records stable failures, and bounds bodies" do
    fetcher = fn
      "https://one.example", _opts ->
        {:ok,
         %{
           url: "https://one.example/final",
           content_type: "text/plain",
           text: String.duplicate("e", 30_000),
           bytes: 30_000,
           status: 200,
           redirects: []
         }}

      "https://two.example", _opts ->
        {:ok,
         %{
           url: "https://two.example",
           content_type: "text/plain",
           text: "second source",
           bytes: 13,
           status: 200,
           redirects: []
         }}
    end

    params = %{
      "sources" => [
        %{
          "id" => "source-1",
          "url" => "https://one.example",
          "title" => "One",
          "provider" => "brave",
          "plane" => "ranked_results",
          "query" => "beam",
          "snippet" => "old",
          "provenance" => [%{"provider" => "brave", "url" => "https://one.example"}]
        },
        %{"id" => "source-2", "url" => "https://two.example", "title" => "Two"}
      ],
      "max_body_bytes" => 750_000,
      "max_text_chars" => 20_000,
      "max_parallel_fetches" => 2
    }

    assert {:ok,
            %{
              "sources" => [one, two],
              "usage" => %{"request_count" => 2, "cost_cents" => 0}
            }} =
             DagRuntime.fetch_sources(params, context(self()), fetcher_module: fetcher)

    assert one["id"] == "source-1"
    assert one["plane"] == "ranked_results"
    assert one["fetched"]
    assert one["fetched_url"] == "https://one.example/final"
    assert String.length(one["snippet"]) == 20_000
    assert String.starts_with?(one["content_hash"], "sha256:")
    refute Map.has_key?(one, "redirects")
    assert two["snippet"] == "second source"
    refute inspect(two) =~ @secret
  end

  test "source fetching honors bounded parallelism and preserves source order" do
    parent = self()

    fetcher = fn url, _opts ->
      send(parent, {:fetch_started, self(), url})

      receive do
        :release ->
          {:ok,
           %{
             url: url,
             content_type: "text/plain",
             text: "body for #{url}",
             bytes: byte_size(url),
             status: 200,
             redirects: []
           }}
      end
    end

    sources =
      Enum.map(1..4, fn index ->
        %{"id" => "source-#{index}", "url" => "https://#{index}.example", "title" => "#{index}"}
      end)

    start_supervised!(
      {Task,
       fn ->
         result =
           DagRuntime.fetch_sources(
             %{"sources" => sources, "max_parallel_fetches" => 2},
             context(parent),
             fetcher_module: fetcher
           )

         send(parent, {:fetch_result, result})
       end}
    )

    first_wave = Enum.map(1..2, fn _ -> receive_fetch_started() end)
    refute_receive {:fetch_started, _pid, _url}, 50
    Enum.each(first_wave, fn {pid, _url} -> send(pid, :release) end)

    second_wave = Enum.map(1..2, fn _ -> receive_fetch_started() end)
    Enum.each(second_wave, fn {pid, _url} -> send(pid, :release) end)

    assert_receive {:fetch_result, {:ok, result}}
    assert Enum.map(result["sources"], & &1["id"]) == Enum.map(1..4, &"source-#{&1}")
    assert result["usage"]["request_count"] == 4
  end

  test "all source fetch failures fail with one stable code" do
    assert {:error, :external_effect_uncertain} =
             DagRuntime.fetch_sources(
               %{"sources" => [%{"url" => "https://example.com"}]},
               context(self()),
               fetcher_module: fn _url, _opts -> {:error, {:secret, @secret}} end
             )
  end

  test "report synthesis uses no tools and returns draft plus normalized usage" do
    parent = self()

    llm = fn messages, system, session, on_chunk, opts ->
      send(parent, {:llm, messages, system, session, on_chunk, opts})
      {:ok, %{text: "# Report\n\nFinding [1].", usage: %{input_tokens: 22, output_tokens: 8}}}
    end

    params = %{
      "objective" => "Assess BEAM",
      "depth" => "high",
      "attachment_context" => [
        %{
          "type" => "deep_research",
          "id" => 42,
          "objective" => "Prior audit",
          "level" => "medium",
          "sha256" => String.duplicate("a", 64),
          "content" => "PRIVATE SYNTHESIS CONTEXT SENTINEL"
        }
      ],
      "sources" => [
        %{
          "url" => "https://example.com",
          "title" => "Evidence",
          "provider" => "brave",
          "snippet" => "bounded evidence"
        }
      ],
      "max_input_tokens" => 2_000,
      "max_output_tokens" => 1_000
    }

    assert {:ok, result} =
             DagRuntime.synthesize_report(
               params,
               context(parent),
               settings_resolver: grounded_settings(),
               session_resolver: fn "session" -> routing_session() end,
               llm_module: llm
             )

    assert_receive {:llm, [message], system, %{id: "session"}, on_chunk, llm_opts}
    assert system =~ "rigorous research analyst"
    assert message.content =~ "PRIVATE SYNTHESIS CONTEXT SENTINEL"
    assert message.content =~ "untrusted"
    assert is_function(on_chunk, 1)
    assert llm_opts[:allowed_tools] == []
    assert llm_opts[:max_tokens] == 1_000

    assert llm_opts[:resolved_route] == %{
             "provider" => "openai",
             "model" => "gpt-test",
             "api_key" => @secret,
             "base_url" => "https://models.example",
             "temperature" => 0.1
           }

    assert result["markdown"] == "# Report\n\nFinding [1]."

    assert result["usage"] == %{
             "input_tokens" => 22,
             "output_tokens" => 8,
             "cost_cents" => 0,
             "request_count" => 1
           }
  end

  test "report synthesis gets a bounded total effect deadline longer than sixty seconds" do
    parent = self()

    provider_effect = fn operation, _descriptor, _estimate, callback, effect_opts ->
      send(parent, {:synthesis_effect_timeout, operation, effect_opts[:timeout_ms]})

      case callback.() do
        {:ok, response, usage} -> effect_receipt(response, usage)
        _other -> {:error, :external_effect_uncertain}
      end
    end

    synthesis_context = put_in(context(parent).provider_effect, provider_effect)

    params = %{
      "objective" => "Assess long-form generation",
      "depth" => "high",
      "sources" => [
        %{
          "url" => "https://example.com",
          "title" => "Evidence",
          "provider" => "brave",
          "snippet" => "bounded evidence"
        }
      ],
      "max_input_tokens" => 2_000,
      "max_output_tokens" => 12_000
    }

    common_opts = [
      settings_resolver: grounded_settings(),
      session_resolver: fn "session" -> routing_session() end,
      llm_module: fn _messages, _system, _session, _on_chunk, _opts ->
        {:ok, %{text: "# Report\n\nFinding [1].", usage: %{}}}
      end
    ]

    assert {:ok, _result} =
             DagRuntime.synthesize_report(params, synthesis_context, common_opts)

    assert_receive {:synthesis_effect_timeout, "research.report_synthesis", 150_000}

    assert {:ok, _result} =
             DagRuntime.synthesize_report(
               params,
               synthesis_context,
               Keyword.put(common_opts, :effect_timeout, 120_000)
             )

    assert_receive {:synthesis_effect_timeout, "research.report_synthesis", 120_000}

    assert {:ok, _result} =
             DagRuntime.synthesize_report(
               params,
               synthesis_context,
               Keyword.put(common_opts, :effect_timeout, 300_000)
             )

    assert_receive {:synthesis_effect_timeout, "research.report_synthesis", 150_000}
  end

  test "fails closed without a trusted effect closure and on bodyless replay" do
    params = %{"provider" => "brave", "query" => "beam"}
    plain = Map.delete(context(self()), :provider_effect)

    assert {:error, :provider_effect_unavailable} =
             DagRuntime.ranked_search(params, plain,
               settings_resolver: ranked_settings(),
               search_module: fn _, _ -> flunk("missing boundary must not dispatch") end
             )

    replay =
      put_in(context(self()).provider_effect, fn _, _, _, _, _ ->
        {:ok, %{replayed?: true, response: nil, usage: %{}}}
      end)

    assert {:error, :provider_effect_replay_without_response} =
             DagRuntime.ranked_search(params, replay,
               settings_resolver: ranked_settings(),
               search_module: fn _, _ -> flunk("replay must not dispatch") end
             )
  end

  test "accepts a verified replay carrying its persisted response body" do
    persisted = %{
      "provider" => "brave",
      "query" => "beam",
      "results" => [],
      "errors" => %{}
    }

    replay =
      put_in(context(self()).provider_effect, fn _, _, _, callback, _ ->
        # The durable effect boundary owns replay and must not invoke callback.
        _ = callback

        {:ok,
         %{
           replayed?: true,
           response: persisted,
           usage: %{requests: 1, input_tokens: 0, output_tokens: 0, cost_cents: 0}
         }}
      end)

    assert {:ok, result} =
             DagRuntime.ranked_search(
               %{"provider" => "brave", "query" => "beam"},
               replay,
               settings_resolver: ranked_settings(),
               search_module: fn _, _ -> flunk("verified replay must not dispatch") end
             )

    assert result["results"] == []
    assert result["usage"]["request_count"] == 1
  end

  defp context(parent) do
    %{
      run: %{session_id: "session"},
      cancelled?: fn -> false end,
      checkpoint_callback: fn payload, progress ->
        phase = get_in(payload, ["research_runtime", "phase"])
        send(parent, {:checkpoint, phase, progress})
        :ok
      end,
      provider_effect: fn operation, descriptor, estimate, callback, _opts ->
        send(parent, {:provider_effect, operation, descriptor, estimate})

        try do
          case callback.() do
            {:ok, response, usage} -> effect_receipt(response, usage)
            _other -> {:error, :external_effect_uncertain}
          end
        rescue
          _error -> {:error, :provider_effect_failed}
        end
      end
    }
  end

  defp research_context(parent, ranked, grounded) do
    put_in(context(parent), [:run, :metadata], %{
      "research" => %{
        "ranked_providers" => ranked,
        "grounded_providers" => grounded
      }
    })
  end

  defp effect_receipt(response, usage) do
    {:ok, %{replayed?: false, response: response, usage: usage}}
  end

  defp receive_fetch_started do
    receive do
      {:fetch_started, pid, url} -> {pid, url}
    after
      1_000 -> flunk("expected bounded source fetch to start")
    end
  end

  defp ranked_settings do
    fn ->
      %{
        "search" => %{
          "providers" => %{"brave" => %{"enabled" => true, "api_key" => @secret}}
        }
      }
    end
  end

  defp grounded_settings do
    fn ->
      %{
        "synthesis_providers" => %{
          "openai" => %{"api_key" => @secret, "base_url" => "https://models.example"}
        },
        "grounded_providers" => %{
          "openai_responses" => %{"api_key" => @secret, "model" => "gpt-test"}
        }
      }
    end
  end

  defp strict_settings(lock_version) do
    %{
      "settings_identity" => %{"id" => "settings-1", "lock_version" => lock_version},
      "search" => %{
        "order" => ["brave", "exa"],
        "providers" => %{
          "brave" => %{
            "enabled" => true,
            "api_key" => @secret,
            "base_url" => "https://brave.example"
          },
          "exa" => %{
            "enabled" => true,
            "api_key" => "unselected-secret",
            "base_url" => "https://exa.example"
          }
        }
      },
      "synthesis_providers" => %{
        "openai" => %{"base_url" => "https://models.example", "api_key" => @secret}
      },
      "grounded_providers" => %{
        "openai_responses" => %{"api_key" => @secret, "model" => "gpt-test"}
      }
    }
  end

  defp routing_session do
    %{id: "session", model_provider: "openai", model_name: "gpt-test"}
  end
end
