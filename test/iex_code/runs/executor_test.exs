defmodule IexCode.Runs.ExecutorTest do
  use ExUnit.Case, async: true

  alias IexCode.Runs.Executor

  test "failed swarm final message is normalized to an executor error" do
    message = %{id: "message-id", metadata: %{status: :failed}, content: "verification failed"}

    assert {:error, {:swarm_failed, ^message}} =
             Executor.normalize_swarm_result({:ok, message})
  end

  test "completed swarm final message remains successful" do
    message = %{id: "message-id", metadata: %{status: :completed}, content: "done"}

    assert {:ok, ^message} = Executor.normalize_swarm_result({:ok, message})
  end

  test "cancelled and stopped swarm results are normalized to cancellation errors" do
    assert {:error, :cancelled} =
             Executor.normalize_swarm_result({:ok, %{cancelled: true}})

    assert {:error, :cancelled} =
             Executor.normalize_swarm_result({:ok, %{metadata: %{"status" => "stopped"}}})
  end
end
