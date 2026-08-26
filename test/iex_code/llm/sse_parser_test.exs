defmodule IexCode.LLM.SSEParserTest do
  use ExUnit.Case, async: false
  alias IexCode.LLM.SSEParser

  describe "OpenAI SSE Stream parsing" do
    test "parses text delta and [DONE] message" do
      chunk = """
      : keepalive
      data: {"id":"chatcmpl-1","choices":[{"delta":{"content":"Hello "},"finish_reason":null}]}

      data: {"id":"chatcmpl-1","choices":[{"delta":{"content":"world!"},"finish_reason":null}]}

      data: {"id":"chatcmpl-1","choices":[{"delta":{},"finish_reason":"stop"}]}

      data: [DONE]

      """

      {events, _st} = SSEParser.parse(SSEParser.new(), chunk)
      assert length(events) == 4

      [e1, e2, e3, e4] = events

      assert {:delta, %{text: "Hello "}} = SSEParser.parse_event(e1, "openai")
      assert {:delta, %{text: "world!"}} = SSEParser.parse_event(e2, "openai")
      assert {:done, "stop", _} = SSEParser.parse_event(e3, "openai")
      assert {:done, :stop} = SSEParser.parse_event(e4, "openai")
    end

    test "parses OpenAI streaming tool call chunks and reasoning" do
      chunk = """
      data: {"choices":[{"delta":{"reasoning_content":"Inspecting directory...","tool_calls":[{"index":0,"id":"call_123","function":{"name":"list_dir","arguments":"{\\"path\\""}}]}}]}

      data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":": \\"lib\\"}"}}]}}]}

      """

      {events, _st} = SSEParser.parse(SSEParser.new(), chunk)
      assert length(events) == 2

      [e1, e2] = events

      assert {:delta, %{reasoning: "Inspecting directory...", tool_calls: [tc1]}} =
               SSEParser.parse_event(e1, "openai")

      assert tc1["id"] == "call_123"
      assert tc1["function"]["name"] == "list_dir"

      assert {:delta, %{tool_calls: [tc2]}} = SSEParser.parse_event(e2, "openai")
      assert tc2["function"]["arguments"] =~ "lib"
    end
  end

  describe "Anthropic SSE Stream parsing" do
    test "parses Anthropic content blocks, tools, and message stop" do
      chunk = """
      event: content_block_start
      data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_01","name":"read_file"}}

      event: content_block_delta
      data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\\"path\\": \\"mix.exs\\"}"}}

      event: content_block_delta
      data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Reading mix.exs"}}

      event: message_delta
      data: {"type":"message_delta","delta":{"stop_reason":"tool_use"}}

      event: message_stop
      data: {"type":"message_stop"}

      """

      {events, _st} = SSEParser.parse(SSEParser.new(), chunk)
      assert length(events) == 5

      [e1, e2, e3, e4, e5] = events

      assert {:delta, %{tool_calls: [tc_start]}} = SSEParser.parse_event(e1, "anthropic")
      assert tc_start["id"] == "toolu_01"
      assert tc_start["function"]["name"] == "read_file"

      assert {:delta, %{tool_calls: [tc_delta]}} = SSEParser.parse_event(e2, "anthropic")
      assert tc_delta["function"]["arguments"] =~ "mix.exs"

      assert {:delta, %{text: "Reading mix.exs"}} = SSEParser.parse_event(e3, "anthropic")
      assert {:done, "tool_use"} = SSEParser.parse_event(e4, "anthropic")
      assert {:done, :stop} = SSEParser.parse_event(e5, "anthropic")
    end
  end

  describe "Line framing and partial chunk buffering" do
    test "correctly buffers partial SSE lines across chunks" do
      st0 = SSEParser.new()

      # Chunk 1 ends in the middle of a data line
      {ev1, st1} = SSEParser.parse(st0, "data: {\"choices\":[{\"delta\":{\"cont")
      assert ev1 == []

      # Chunk 2 completes the line and closes the event
      {ev2, _st2} = SSEParser.parse(st1, "ent\":\"Split successful!\"}}]}\n\n")
      assert length(ev2) == 1
      assert {:delta, %{text: "Split successful!"}} = SSEParser.parse_event(hd(ev2), "openai")
    end
  end
end
