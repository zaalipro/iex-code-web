defmodule IexCode.Research.GroundedSearchTest do
  use ExUnit.Case, async: true

  alias IexCode.Research.GroundedSearch
  alias IexCode.Research.GroundedSearch.{GroundedAnswer, HTTP, Registry}

  test "registry explicitly distinguishes supported hosted transports from Azure" do
    assert Enum.map(Registry.descriptors(), & &1.id) == [
             :openai_responses,
             :anthropic_messages,
             :gemini_interactions,
             :azure_foundry
           ]

    assert {:ok, %{status: :supported, protocol: :responses_web_search}} =
             Registry.descriptor("openai_responses")

    assert {:ok,
            %{
              default_tool_version: "web_search_20260318",
              supported_tool_versions: versions
            }} = Registry.descriptor(:anthropic_messages)

    assert "web_search_20250305" in versions

    assert {:ok, %{status: :unsupported, limitation: limitation}} =
             Registry.descriptor(:azure_foundry)

    assert limitation =~ "project-specific"
    assert {:error, {:unsupported_provider, ^limitation}} = Registry.fetch(:azure_foundry)
    assert {:error, {:unknown_provider, :ranked_results}} = Registry.fetch(:ranked_results)
  end

  test "the public facade returns a synthesized GroundedAnswer, not ranked results" do
    request = fn opts ->
      send(self(), {:request, opts})

      {:ok,
       %{
         status: 200,
         body: %{
           "id" => "resp_1",
           "status" => "completed",
           "model" => "gpt-test",
           "output" => [
             %{
               "type" => "web_search_call",
               "id" => "ws_1",
               "status" => "completed",
               "action" => %{"type" => "search", "query" => "current BEAM release"}
             },
             %{
               "type" => "message",
               "content" => [
                 %{
                   "type" => "output_text",
                   "text" => "OTP 28 is current.",
                   "annotations" => [
                     %{
                       "type" => "url_citation",
                       "url" => "https://www.erlang.org/news/otp-28",
                       "title" => "OTP 28",
                       "start_index" => 0,
                       "end_index" => 6
                     }
                   ]
                 }
               ]
             }
           ],
           "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
         }
       }}
    end

    assert {:ok, %GroundedAnswer{} = grounded} =
             GroundedSearch.answer(:openai_responses, "Which OTP is current?",
               api_key: "openai-secret",
               model: "gpt-test",
               request: request
             )

    assert grounded.answer == "OTP 28 is current."
    assert grounded.provider == :openai_responses

    assert [%{url: "https://www.erlang.org/news/otp-28", start_index: 0}] =
             grounded.citations

    assert [%{queries: ["current BEAM release"]}] = grounded.search_calls
    refute Map.has_key?(grounded, :results)

    assert_receive {:request, request_opts}
    assert request_opts[:url] == "https://api.openai.com/v1/responses"
    assert request_opts[:json]["tools"] == [%{"type" => "web_search"}]
    assert request_opts[:json]["tool_choice"] == "required"
    assert {"authorization", "Bearer openai-secret"} in request_opts[:headers]
  end

  test "cancellation is checked before transport and empty grounding proof is rejected" do
    never = fn _opts -> flunk("cancelled request must not issue HTTP") end

    assert {:error, :cancelled} =
             GroundedSearch.answer(:openai_responses, "query",
               api_key: "key",
               model: "model",
               cancelled?: fn -> true end,
               request: never
             )

    ungrounded = fn _opts ->
      {:ok,
       %{
         status: 200,
         body: %{
           "status" => "completed",
           "output" => [
             %{
               "type" => "message",
               "content" => [%{"type" => "output_text", "text" => "No search."}]
             }
           ]
         }
       }}
    end

    assert {:error, {:ungrounded_response, :no_search_calls}} =
             GroundedSearch.answer(:openai_responses, "query",
               api_key: "key",
               model: "model",
               request: ungrounded
             )
  end

  test "grounded provider credentials reject model identifiers over 240 bytes before transport" do
    never = fn _opts -> flunk("oversized model must not issue HTTP") end

    assert {:error, {:configuration, :invalid_api_key_or_model}} =
             GroundedSearch.answer(:openai_responses, "query",
               api_key: "key",
               model: String.duplicate("m", 241),
               request: never
             )
  end

  test "OpenAI option filters fail closed and failed hosted calls are not grounding proof" do
    never = fn _opts -> flunk("invalid options must fail before transport") end

    assert {:error, {:configuration, :invalid_allowed_domains}} =
             GroundedSearch.answer(:openai_responses, "query",
               api_key: "key",
               model: "model",
               allowed_domains: ["https://example.com"],
               request: never
             )

    assert {:error, {:configuration, {:invalid_option, :external_web_access}}} =
             GroundedSearch.answer(:openai_responses, "query",
               api_key: "key",
               model: "model",
               external_web_access: "false",
               request: never
             )

    failed_call = fn _opts ->
      {:ok,
       %{
         status: 200,
         body: %{
           "status" => "completed",
           "output" => [
             %{"type" => "web_search_call", "status" => "failed"},
             %{
               "type" => "message",
               "content" => [
                 %{
                   "type" => "output_text",
                   "text" => "Untrusted answer",
                   "annotations" => [
                     %{"type" => "url_citation", "url" => "https://example.com"}
                   ]
                 }
               ]
             }
           ]
         }
       }}
    end

    assert {:error, {:provider_error, {:web_search, "failed"}}} =
             GroundedSearch.answer(:openai_responses, "query",
               api_key: "key",
               model: "model",
               request: failed_call
             )
  end

  test "unsafe or out-of-range provider citations are not accepted" do
    response = fn _opts ->
      {:ok,
       %{
         status: 200,
         body: %{
           "status" => "completed",
           "output" => [
             %{"type" => "web_search_call", "status" => "completed"},
             %{
               "type" => "message",
               "content" => [
                 %{
                   "type" => "output_text",
                   "text" => "Short answer.",
                   "annotations" => [
                     %{
                       "type" => "url_citation",
                       "url" => "http://127.0.0.1/private",
                       "start_index" => 0,
                       "end_index" => 5
                     },
                     %{
                       "type" => "url_citation",
                       "url" => "https://example.com/source",
                       "start_index" => 0,
                       "end_index" => 10_000
                     }
                   ]
                 }
               ]
             }
           ]
         }
       }}
    end

    assert {:error, {:ungrounded_response, :no_citations}} =
             GroundedSearch.answer(:openai_responses, "query",
               api_key: "key",
               model: "model",
               request: response
             )
  end

  test "official origin allowlist and bounded redacted errors fail closed" do
    assert {:error, {:configuration, :unofficial_endpoint}} =
             HTTP.post(
               :openai_responses,
               "https://attacker.example/v1/responses",
               "secret",
               [json: %{}],
               request: fn _ -> flunk("unofficial origin must not be requested") end
             )

    leaking = fn _opts -> raise "upstream echoed top-secret-key" end

    assert {:error, reason} =
             GroundedSearch.answer(:openai_responses, "query",
               api_key: "top-secret-key",
               model: "model",
               request: leaking
             )

    inspected = inspect(reason)
    assert inspected =~ "[REDACTED]"
    refute inspected =~ "top-secret-key"

    oversized = fn _opts -> {:ok, %{status: 200, body: String.duplicate("x", 2_000_001)}} end

    assert {:error, :response_too_large} =
             GroundedSearch.answer(:openai_responses, "query",
               api_key: "key",
               model: "model",
               request: oversized
             )
  end
end
