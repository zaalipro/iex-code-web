defmodule IexCode.LLM.ContextCompactorTest do
  use ExUnit.Case, async: true
  alias IexCode.Settings.AppSettings
  alias IexCode.LLM.ContextCompactor

  describe "estimate_tokens/1" do
    test "estimates string token count" do
      tokens = ContextCompactor.estimate_tokens("Hello world, this is a test string.")
      assert tokens > 0
    end

    test "estimates message map token count" do
      msg = %{role: "user", content: "Hello world"}
      assert ContextCompactor.estimate_tokens(msg) > 0
    end

    test "estimates list of messages" do
      messages = [
        %{role: "user", content: "Write a poem"},
        %{role: "assistant", content: "Roses are red, violets are blue"}
      ]

      assert ContextCompactor.estimate_tokens(messages) > 10
    end
  end

  describe "compact/3 threshold logic" do
    test "returns messages unchanged when below threshold" do
      settings = %AppSettings{
        context_window_tokens: 100_000,
        context_prune_threshold_percent: 75,
        context_compaction_strategy: "sliding_window"
      }

      messages = [
        %{role: "user", content: "Short question"},
        %{role: "assistant", content: "Short answer"}
      ]

      assert ContextCompactor.compact(messages, settings) == messages
    end

    test "handles empty message list" do
      assert ContextCompactor.compact([], %AppSettings{}) == []
    end
  end

  describe "compact/3 sliding_window strategy" do
    test "keeps root message and latest K turns when threshold exceeded" do
      settings = %AppSettings{
        context_window_tokens: 100,
        context_prune_threshold_percent: 10,
        context_compaction_strategy: "sliding_window",
        keep_recent_turns: 2
      }

      messages = [
        %{role: "user", content: "Root task: build app"},
        %{role: "assistant", content: "Intermediate turn 1"},
        %{role: "user", content: "Intermediate turn 2"},
        %{role: "assistant", content: "Intermediate turn 3"},
        %{role: "user", content: "Recent turn 4"},
        %{role: "assistant", content: "Recent turn 5"}
      ]

      compacted = ContextCompactor.compact(messages, settings)
      assert length(compacted) == 3
      assert hd(compacted).content == "Root task: build app"
      assert Enum.at(compacted, 1).content == "Recent turn 4"
      assert Enum.at(compacted, 2).content == "Recent turn 5"
    end
  end

  for strategy <- ["sliding_window", "rolling_summary", "token_compaction"],
      keys <- [:atoms, :strings] do
    @strategy strategy
    @keys keys
    test "#{strategy} preserves a parallel tool exchange with #{keys} keys" do
      messages = [
        %{role: "user", content: "Root task"},
        %{role: "assistant", content: String.duplicate("Old context ", 100)},
        %{
          role: "assistant",
          content: "",
          tool_calls: [
            %{id: "first", name: "read_file", args: %{}},
            %{id: "second", name: "read_file", args: %{}}
          ]
        },
        %{role: "tool", content: "First result", tool_call_id: "first"},
        %{role: "tool", content: "Second result", tool_call_id: "second"}
      ]

      messages =
        if @keys == :strings,
          do:
            Enum.map(messages, &Map.new(&1, fn {key, value} -> {Atom.to_string(key), value} end)),
          else: messages

      compacted =
        ContextCompactor.compact(messages, %{
          context_window_tokens: 100,
          context_prune_threshold_percent: 10,
          context_compaction_strategy: @strategy,
          keep_recent_turns: 1
        })

      assert hd(compacted) == hd(messages)
      assert Enum.take(compacted, -3) == Enum.take(messages, -3)
      refute Enum.at(messages, 1) in compacted
    end
  end

  describe "compact/3 rolling_summary strategy" do
    test "replaces older turns with a summary checkpoint while keeping root and recent turns" do
      settings = %AppSettings{
        context_window_tokens: 100,
        context_prune_threshold_percent: 10,
        context_compaction_strategy: "rolling_summary",
        keep_recent_turns: 2
      }

      messages = [
        %{role: "user", content: "Root task: refactor code"},
        %{role: "assistant", content: "Found 12 modules needing fixes"},
        %{role: "user", content: "Go ahead and fix module A"},
        %{role: "assistant", content: "Module A fixed cleanly"},
        %{role: "user", content: "Fix module B"},
        %{role: "assistant", content: "Module B fixed cleanly"}
      ]

      compacted = ContextCompactor.compact(messages, settings)
      assert length(compacted) == 4
      assert hd(compacted).content == "Root task: refactor code"

      summary = Enum.at(compacted, 1)
      assert summary.role == "system"
      assert summary.content =~ "Summary of earlier conversation history"
      assert summary.content =~ "Found 12 modules"

      assert Enum.at(compacted, 2).content == "Fix module B"
      assert Enum.at(compacted, 3).content == "Module B fixed cleanly"
    end
  end

  describe "compact/3 token_compaction strategy" do
    test "truncates voluminous tool output" do
      bulky_tool_output =
        "Exit Code 0:\n" <>
          Enum.map_join(1..200, "\n", fn i -> "Line #{i}: search result item data #{i}..." end)

      settings = %AppSettings{
        context_window_tokens: 200,
        context_prune_threshold_percent: 10,
        context_compaction_strategy: "token_compaction",
        keep_recent_turns: 2
      }

      messages = [
        %{role: "user", content: "Grep for something"},
        %{role: "tool", content: bulky_tool_output},
        %{role: "assistant", content: "Found results"}
      ]

      compacted = ContextCompactor.compact(messages, settings)
      tool_msg = Enum.find(compacted, &(&1.role in ["tool", :tool]))

      assert tool_msg != nil
      assert tool_msg.content =~ "Exit Code 0"
      assert tool_msg.content =~ "compacted"
      assert byte_size(tool_msg.content) < byte_size(bulky_tool_output)
    end

    test "compacts few-line massive output (< 16 lines) without size expansion or negative lines" do
      two_line_output = "Exit Code 0\n" <> String.duplicate("A", 20_000)
      msg = %{"role" => "tool", "content" => two_line_output}

      compacted = ContextCompactor.compact_tool_message(msg)
      content = compacted["content"]

      assert byte_size(content) < byte_size(two_line_output)
      assert byte_size(content) < 2_000
      refute content =~ "compacted -"
      assert content =~ "compacted"
      assert content =~ "Exit Code 0"
    end

    test "avoids duplicate exit code in header when exit code is at line 1" do
      multiline =
        "Exit Code 1\n" <>
          Enum.map_join(1..50, "\n", fn i -> "line #{i}: error details exceeding limit" end)

      msg = %{"role" => "tool", "content" => multiline}
      compacted = ContextCompactor.compact_tool_message(msg)
      content = compacted["content"]

      refute content =~ "Exit Code 1\nExit Code 1\n"
      assert String.starts_with?(content, "Exit Code 1\nline 1:")
    end
  end

  describe "compact/3 rolling_summary token bounding" do
    test "bounds total estimated tokens to target_tokens for large histories" do
      large_history =
        Enum.flat_map(1..100, fn i ->
          [
            %{"role" => "user", "content" => "Request #{i} #{String.duplicate("info ", 10)}"},
            %{
              "role" => "assistant",
              "content" => "Response #{i} #{String.duplicate("done ", 10)}"
            }
          ]
        end)

      messages = [%{"role" => "user", "content" => "Root task"} | large_history]

      settings = %AppSettings{
        context_window_tokens: 2_000,
        context_prune_threshold_percent: 50,
        context_compaction_strategy: "rolling_summary",
        keep_recent_turns: 4
      }

      compacted = ContextCompactor.compact(messages, settings)
      compacted_tokens = ContextCompactor.estimate_tokens(compacted)
      trigger_budget = 1_000

      assert compacted_tokens <= trigger_budget
      assert length(compacted) == 6
      assert Enum.at(compacted, 1)["role"] == "system"
      assert Enum.at(compacted, 1)["content"] =~ "Summary of earlier conversation history"
    end
  end
end
