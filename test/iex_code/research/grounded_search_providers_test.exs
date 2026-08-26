defmodule IexCode.Research.GroundedSearchProvidersTest do
  use ExUnit.Case, async: true

  alias IexCode.Research.GroundedSearch

  test "Anthropic Messages continues pause_turn unchanged and normalizes calls, citations, and usage" do
    test_pid = self()

    request = fn opts ->
      send(test_pid, {:anthropic_request, opts})

      case Process.get(:anthropic_request_count, 0) do
        0 ->
          Process.put(:anthropic_request_count, 1)

          {:ok,
           %{
             status: 200,
             body: %{
               "id" => "msg_pause",
               "model" => "claude-test",
               "stop_reason" => "pause_turn",
               "content" => [
                 %{
                   "type" => "server_tool_use",
                   "id" => "srv_1",
                   "name" => "web_search",
                   "input" => %{"query" => "latest Elixir release"}
                 },
                 %{
                   "type" => "web_search_tool_result",
                   "tool_use_id" => "srv_1",
                   "content" => [
                     %{
                       "type" => "web_search_result",
                       "url" => "https://elixir-lang.org/blog/",
                       "title" => "Elixir blog",
                       "encrypted_content" => "opaque-provider-state"
                     }
                   ]
                 }
               ],
               "usage" => %{"input_tokens" => 3, "output_tokens" => 4}
             }
           }}

        1 ->
          Process.put(:anthropic_request_count, 2)

          {:ok,
           %{
             status: 200,
             body: %{
               "id" => "msg_final",
               "model" => "claude-test",
               "stop_reason" => "end_turn",
               "content" => [
                 %{
                   "type" => "text",
                   "text" => "Elixir 1.19 is available.",
                   "citations" => [
                     %{
                       "type" => "web_search_result_location",
                       "url" => "https://elixir-lang.org/blog/",
                       "title" => "Elixir blog",
                       "cited_text" => "Elixir 1.19"
                     }
                   ]
                 }
               ],
               "usage" => %{
                 "input_tokens" => 5,
                 "output_tokens" => 6,
                 "server_tool_use" => %{"web_search_requests" => 1}
               }
             }
           }}
      end
    end

    assert {:ok, answer} =
             GroundedSearch.answer(:anthropic_messages, "Find the latest Elixir release",
               api_key: "anthropic-secret",
               model: "claude-test",
               request: request
             )

    assert answer.answer == "Elixir 1.19 is available."
    assert answer.metadata["continuations"] == 1
    assert answer.usage["input_tokens"] == 8
    assert answer.usage["output_tokens"] == 10
    assert [%{id: "srv_1", queries: ["latest Elixir release"]}] = answer.search_calls
    assert [%{cited_text: "Elixir 1.19"}] = answer.citations

    assert_receive {:anthropic_request, first}
    assert first[:url] == "https://api.anthropic.com/v1/messages"

    assert first[:json]["tools"] == [
             %{
               "type" => "web_search_20260318",
               "name" => "web_search",
               "max_uses" => 5,
               "allowed_callers" => ["direct"],
               "response_inclusion" => "full"
             }
           ]

    assert first[:json]["messages"] == [
             %{"role" => "user", "content" => "Find the latest Elixir release"}
           ]

    assert_receive {:anthropic_request, second}

    assert List.last(second[:json]["messages"]) == %{
             "role" => "assistant",
             "content" => first_pause_content()
           }
  end

  test "Anthropic embedded 200 tool errors and conflicting filters remain errors" do
    tool_error = fn _opts ->
      {:ok,
       %{
         status: 200,
         body: %{
           "stop_reason" => "end_turn",
           "content" => [
             %{
               "type" => "web_search_tool_result",
               "content" => %{
                 "type" => "web_search_tool_result_error",
                 "error_code" => "max_uses_exceeded"
               }
             }
           ]
         }
       }}
    end

    assert {:error, {:provider_error, {:web_search, "max_uses_exceeded"}}} =
             GroundedSearch.answer(:anthropic_messages, "query",
               api_key: "key",
               model: "model",
               request: tool_error
             )

    assert {:error, {:configuration, :conflicting_domain_filters}} =
             GroundedSearch.answer(:anthropic_messages, "query",
               api_key: "key",
               model: "model",
               allowed_domains: ["example.com"],
               blocked_domains: ["bad.example"],
               request: fn _ -> flunk("invalid config must not request") end
             )

    assert {:error, {:configuration, :invalid_domain_filter}} =
             GroundedSearch.answer(:anthropic_messages, "query",
               api_key: "key",
               model: "model",
               blocked_domains: ["bad.example\nignored.example"],
               request: fn _ -> flunk("invalid filters must not be silently omitted") end
             )
  end

  test "Anthropic re-checks cancellation before a pause_turn continuation" do
    Process.put(:cancel_checks, 0)

    cancelled = fn ->
      checks = Process.get(:cancel_checks, 0)
      Process.put(:cancel_checks, checks + 1)
      checks >= 1
    end

    request = fn _opts ->
      Process.put(:issued_requests, Process.get(:issued_requests, 0) + 1)

      {:ok,
       %{
         status: 200,
         body: %{
           "stop_reason" => "pause_turn",
           "content" => first_pause_content(),
           "usage" => %{}
         }
       }}
    end

    assert {:error, :cancelled} =
             GroundedSearch.answer(:anthropic_messages, "query",
               api_key: "key",
               model: "model",
               cancelled?: cancelled,
               request: request
             )

    assert Process.get(:issued_requests) == 1
  end

  test "Anthropic allows an explicit basic compatibility tool version" do
    test_pid = self()

    request = fn opts ->
      send(test_pid, {:version_request, opts})

      {:ok,
       %{
         status: 200,
         body: %{
           "stop_reason" => "end_turn",
           "content" => [
             %{
               "type" => "server_tool_use",
               "id" => "srv_legacy",
               "name" => "web_search",
               "input" => %{"query" => "query"}
             },
             %{
               "type" => "web_search_tool_result",
               "tool_use_id" => "srv_legacy",
               "content" => [
                 %{
                   "type" => "web_search_result",
                   "url" => "https://example.com/source",
                   "title" => "Source",
                   "encrypted_content" => "opaque"
                 }
               ]
             },
             %{
               "type" => "text",
               "text" => "Answer.",
               "citations" => [
                 %{
                   "type" => "web_search_result_location",
                   "url" => "https://example.com/source",
                   "title" => "Source"
                 }
               ]
             }
           ]
         }
       }}
    end

    assert {:ok, _answer} =
             GroundedSearch.answer(:anthropic_messages, "query",
               api_key: "key",
               model: "model",
               tool_version: "web_search_20250305",
               request: request
             )

    assert_receive {:version_request, legacy}
    assert hd(legacy[:json]["tools"])["type"] == "web_search_20250305"
    refute Map.has_key?(hd(legacy[:json]["tools"]), "response_inclusion")

    assert {:error, {:configuration, :unsupported_tool_version}} =
             GroundedSearch.answer(:anthropic_messages, "query",
               api_key: "key",
               model: "model",
               tool_version: "web_search_future",
               request: fn _ -> flunk("unknown tool versions must fail before transport") end
             )
  end

  test "Gemini Interactions pins the revision and normalizes timeline grounding" do
    test_pid = self()

    request = fn opts ->
      send(test_pid, {:gemini_request, opts})

      {:ok,
       %{
         status: 200,
         body: %{
           "id" => "int_1",
           "status" => "completed",
           "model" => "gemini-test",
           "steps" => [
             %{
               "type" => "google_search_call",
               "id" => "gs_1",
               "arguments" => %{"queries" => ["Euro 2024 winner"]}
             },
             %{
               "type" => "google_search_result",
               "call_id" => "gs_1",
               "result" => %{"search_suggestions" => "<div>suggestion</div>"}
             },
             %{
               "type" => "model_output",
               "content" => [
                 %{
                   "type" => "text",
                   "text" => "Spain won Euro 2024.",
                   "annotations" => [
                     %{
                       "type" => "url_citation",
                       "url" => "https://www.uefa.com/euro2024/",
                       "title" => "UEFA",
                       "start_index" => 0,
                       "end_index" => 5
                     }
                   ]
                 }
               ]
             }
           ],
           "usage_metadata" => %{"total_token_count" => 42}
         }
       }}
    end

    assert {:ok, answer} =
             GroundedSearch.answer(:gemini_interactions, "Who won Euro 2024?",
               api_key: "gemini-secret",
               model: "gemini-test",
               request: request
             )

    assert answer.answer == "Spain won Euro 2024."
    assert answer.provider == :gemini_interactions
    assert answer.metadata["lifecycle"] == "beta"
    assert answer.usage == %{"total_token_count" => 42}
    assert [%{queries: ["Euro 2024 winner"]}] = answer.search_calls
    assert [%{metadata: %{"index_unit" => "bytes"}}] = answer.citations

    assert_receive {:gemini_request, opts}
    assert opts[:url] == "https://generativelanguage.googleapis.com/v1beta/interactions"
    assert {"api-revision", "2026-05-20"} in opts[:headers]
    assert {"x-goog-api-key", "gemini-secret"} in opts[:headers]
    assert opts[:json]["tools"] == [%{"type" => "google_search"}]
  end

  defp first_pause_content do
    [
      %{
        "type" => "server_tool_use",
        "id" => "srv_1",
        "name" => "web_search",
        "input" => %{"query" => "latest Elixir release"}
      },
      %{
        "type" => "web_search_tool_result",
        "tool_use_id" => "srv_1",
        "content" => [
          %{
            "type" => "web_search_result",
            "url" => "https://elixir-lang.org/blog/",
            "title" => "Elixir blog",
            "encrypted_content" => "opaque-provider-state"
          }
        ]
      }
    ]
  end
end
