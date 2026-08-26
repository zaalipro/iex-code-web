defmodule IexCode.Research.DagFanoutTest do
  use ExUnit.Case, async: true

  alias IexCode.Research.{DagFanout, LevelPolicy}

  test "uses the named level bound and preserves deterministic result order" do
    context = context("ultra")
    parent = self()

    start_supervised!(
      {Task,
       fn ->
         result =
           DagFanout.map(Enum.to_list(1..20), context, fn value ->
             send(parent, {:subagent_started, self()})

             receive do
               :release -> value * 2
             end
           end)

         send(parent, {:fanout_result, result})
       end}
    )

    first_wave = Enum.map(1..10, fn _index -> receive_started() end)
    refute_receive {:subagent_started, _pid}, 50
    Enum.each(first_wave, &send(&1, :release))

    second_wave = Enum.map(1..10, fn _index -> receive_started() end)
    Enum.each(second_wave, &send(&1, :release))

    assert_receive {:fanout_result, {:ok, results}}
    assert results == Enum.map(1..20, &(&1 * 2))
  end

  test "fails closed when the step lead observes cancellation" do
    context = %{context("low") | cancelled?: fn -> true end}
    assert {:error, :cancelled} = DagFanout.map([1, 2], context, & &1)
  end

  defp context(level) do
    {:ok, policy} = LevelPolicy.fetch(level)

    %{
      level_policy: LevelPolicy.durable(policy),
      cancelled?: fn -> false end
    }
  end

  defp receive_started do
    receive do
      {:subagent_started, pid} -> pid
    after
      1_000 -> flunk("expected bounded research subagent to start")
    end
  end
end
