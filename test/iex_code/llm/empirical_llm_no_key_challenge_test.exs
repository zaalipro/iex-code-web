defmodule IexCode.LLM.EmpiricalLlmNoKeyChallengeTest do
  use IexCode.DataCase, async: false
  alias IexCode.LLM
  alias IexCode.LLM.{OpenAI, Anthropic}
  alias IexCode.Settings

  setup do
    # Temporarily ensure API keys in settings and env are cleared for clean testing
    orig_openai = System.get_env("OPENAI_API_KEY")
    orig_anthropic = System.get_env("ANTHROPIC_API_KEY")

    System.delete_env("OPENAI_API_KEY")
    System.delete_env("ANTHROPIC_API_KEY")

    on_exit(fn ->
      if orig_openai, do: System.put_env("OPENAI_API_KEY", orig_openai)
      if orig_anthropic, do: System.put_env("ANTHROPIC_API_KEY", orig_anthropic)
    end)

    :ok
  end

  describe "LLM without API Keys - Strict Error Return & Zero Fabrication" do
    test "OpenAI.chat returns {:error, :no_api_key} when api_key is empty string or nil" do
      chunk_collector = start_chunk_collector()

      # Test with empty string
      result_empty =
        OpenAI.chat(
          [%{role: "user", content: "Explain quantum computing in 3 words"}],
          "You are an assistant",
          [api_key: ""],
          fn chunk -> send(chunk_collector, {:chunk, chunk}) end
        )

      assert result_empty == {:error, :no_api_key}

      # Test with nil
      result_nil =
        OpenAI.chat(
          [%{role: "user", content: "Hello"}],
          "You are an assistant",
          [api_key: nil],
          fn chunk -> send(chunk_collector, {:chunk, chunk}) end
        )

      assert result_nil == {:error, :no_api_key}

      # Test with opts missing :api_key key completely
      result_omitted =
        OpenAI.chat(
          [%{role: "user", content: "Hello"}],
          "You are an assistant",
          [],
          fn chunk -> send(chunk_collector, {:chunk, chunk}) end
        )

      assert result_omitted == {:error, :no_api_key}

      # Assert NO chunks were ever streamed or fabricated
      refute_receive {:chunk, _}
    end

    test "Anthropic.chat returns {:error, :no_api_key} when api_key is empty string or nil" do
      chunk_collector = start_chunk_collector()

      # Test with empty string
      result_empty =
        Anthropic.chat(
          [%{role: "user", content: "Explain relativity"}],
          "You are an assistant",
          [api_key: ""],
          fn chunk -> send(chunk_collector, {:chunk, chunk}) end
        )

      assert result_empty == {:error, :no_api_key}

      # Test with nil
      result_nil =
        Anthropic.chat(
          [%{role: "user", content: "Hello"}],
          "You are an assistant",
          [api_key: nil],
          fn chunk -> send(chunk_collector, {:chunk, chunk}) end
        )

      assert result_nil == {:error, :no_api_key}

      # Test with opts missing :api_key key completely
      result_omitted =
        Anthropic.chat(
          [%{role: "user", content: "Hello"}],
          "You are an assistant",
          [],
          fn chunk -> send(chunk_collector, {:chunk, chunk}) end
        )

      assert result_omitted == {:error, :no_api_key}

      # Assert NO chunks were ever streamed or fabricated
      refute_receive {:chunk, _}
    end

    test "Unified LLM.chat returns {:error, :no_api_key} when settings has no configured keys" do
      # Ensure database settings has empty keys
      {:ok, _} =
        Settings.update_settings(%{
          openai_api_key: "",
          anthropic_api_key: ""
        })

      chunk_collector = start_chunk_collector()

      session = %{
        model_provider: "openai",
        model_name: "gpt-4o",
        temperature: 0.2
      }

      result =
        LLM.chat(
          [%{role: "user", content: "Generate a Phoenix module"}],
          "System prompt",
          session,
          fn chunk -> send(chunk_collector, {:chunk, chunk}) end
        )

      assert result == {:error, :no_api_key}

      # Also test with nil session
      result_nil_session =
        LLM.chat(
          [%{role: "user", content: "Generate a test"}],
          "System prompt",
          nil,
          fn chunk -> send(chunk_collector, {:chunk, chunk}) end
        )

      assert result_nil_session == {:error, :no_api_key}

      # Assert NO chunks received
      refute_receive {:chunk, _}
    end
  end

  defp start_chunk_collector do
    self()
  end
end
