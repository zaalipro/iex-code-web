defmodule IexCode.Engine.AgentStateHygieneTest do
  use ExUnit.Case, async: false

  alias IexCode.Engine.{AgentCancellation, AgentStateRetention}

  setup do
    previous = Application.get_env(:iex_code, :agent_state_retention)

    Application.put_env(:iex_code, :agent_state_retention,
      inline_bytes: 128,
      preview_bytes: 32,
      history_items: 3,
      history_bytes: 2_048
    )

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:iex_code, :agent_state_retention)
      else
        Application.put_env(:iex_code, :agent_state_retention, previous)
      end
    end)

    :ok
  end

  test "small results preserve get_state compatibility" do
    result = %{summary: "ready", failures: []}
    assert AgentStateRetention.retain(result) == result
    assert {^result, [^result]} = AgentStateRetention.remember([], result)
  end

  test "large results become bounded summaries and histories remain bounded" do
    large = String.duplicate("large-agent-result-", 10_000)

    assert {summary, history} = AgentStateRetention.remember([], large)
    assert AgentStateRetention.summary?(summary)
    assert summary.kind == :binary
    assert summary.bytes >= byte_size(large)
    assert byte_size(summary.preview) < 256
    refute inspect(summary) =~ large

    {_latest, history} =
      Enum.reduce(1..20, {nil, history}, fn index, {_retained, current} ->
        AgentStateRetention.remember(current, large <> Integer.to_string(index))
      end)

    assert length(history) == 3
    assert Enum.all?(history, &AgentStateRetention.summary?/1)
    assert :erlang.external_size(history) < 2_048
  end

  test "atomics cancellation is process-local and legacy persistent terms are erased" do
    left = AgentCancellation.new()
    right = AgentCancellation.new()

    refute AgentCancellation.cancelled?(left)
    refute AgentCancellation.cancelled?(right)

    assert :ok = AgentCancellation.cancel(left)
    assert AgentCancellation.cancelled?(left)
    refute AgentCancellation.cancelled?(right)

    assert :ok = AgentCancellation.resume(left)
    refute AgentCancellation.cancelled?(left)

    session_id = Ecto.UUID.generate()
    key = {__MODULE__, :cancelled?, session_id}
    :persistent_term.put(key, String.duplicate("stale", 1_000))

    assert :ok = AgentCancellation.erase_legacy(__MODULE__, session_id)
    assert :persistent_term.get(key, :missing) == :missing
    assert :ok = AgentCancellation.erase_legacy(__MODULE__, session_id)
  end
end
