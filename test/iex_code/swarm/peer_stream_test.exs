defmodule IexCode.Swarm.PeerStreamTest do
  use ExUnit.Case, async: false

  alias IexCode.Swarm.PeerStream

  setup do
    swarm_id = "test-swarm-#{System.unique_integer([:positive])}"
    PeerStream.clear_history(swarm_id)

    on_exit(fn ->
      PeerStream.clear_history(swarm_id)
    end)

    {:ok, swarm_id: swarm_id}
  end

  describe "PubSub Peer Messaging" do
    test "broadcasts and receives {:swarm_peer_message, ...} on topic swarm:id", %{
      swarm_id: swarm_id
    } do
      :ok = PeerStream.subscribe(swarm_id)

      payload = %{"action" => "inspect_target", "files" => ["lib/core.ex"]}

      assert {:ok, sent_msg} =
               PeerStream.broadcast_peer_message(
                 swarm_id,
                 "explorer-1",
                 "architect-lead",
                 :explorer,
                 :context_handoff,
                 payload
               )

      assert sent_msg.swarm_id == swarm_id
      assert sent_msg.from_agent == "explorer-1"
      assert sent_msg.to_agent == "architect-lead"
      assert sent_msg.role == :explorer
      assert sent_msg.type == :context_handoff
      assert sent_msg.payload == payload
      assert %DateTime{} = sent_msg.timestamp

      assert_receive {:swarm_peer_message, received_msg}, 500
      assert received_msg.id == sent_msg.id
      assert received_msg.payload == payload
    end

    test "broadcasts to global swarm:telemetry topic", %{swarm_id: swarm_id} do
      :ok = PeerStream.subscribe_telemetry()

      {:ok, sent_msg} =
        PeerStream.broadcast_peer_message(
          swarm_id,
          "coder-1",
          "swarm:all",
          :coder,
          :proposal_submission,
          %{"patches" => []}
        )

      assert_receive {:swarm_peer_message, received_msg}, 500
      assert received_msg.id == sent_msg.id
    end
  end

  describe "Swarm Telemetry Broadcasting" do
    test "broadcasts and receives {:swarm_telemetry, ...} with token usage and consensus metrics",
         %{swarm_id: swarm_id} do
      :ok = PeerStream.subscribe(swarm_id)
      :ok = PeerStream.subscribe_telemetry()

      telemetry_data = %{
        active_roles: [:explorer, :architect, :coder, :auditor],
        consensus_score: 0.88,
        concordance: 0.94,
        message_count: 5,
        active_turn: 2,
        token_usage: %{
          input_tokens: 1500,
          output_tokens: 450,
          total_tokens: 1950
        },
        stage: :consensus
      }

      assert {:ok, sent_tel} = PeerStream.broadcast_telemetry(swarm_id, telemetry_data)
      assert sent_tel.swarm_id == swarm_id
      assert sent_tel.consensus_score == 0.88
      assert sent_tel.concordance == 0.94
      assert sent_tel.stage == :consensus

      # Should receive on swarm topic and telemetry topic
      assert_receive {:swarm_telemetry, tel_msg1}, 500
      assert tel_msg1.swarm_id == swarm_id
      assert tel_msg1.token_usage.total_tokens == 1950

      assert_receive {:swarm_telemetry, tel_msg2}, 500
      assert tel_msg2.swarm_id == swarm_id
    end
  end

  describe "Chronological Ordering & History Accumulation" do
    test "maintains chronological message ordering under sequential transmissions", %{
      swarm_id: swarm_id
    } do
      {:ok, msg1} =
        PeerStream.broadcast_peer_message(
          swarm_id,
          "explorer-1",
          "architect-lead",
          :explorer,
          :context_handoff,
          %{"step" => 1}
        )

      :timer.sleep(5)

      {:ok, msg2} =
        PeerStream.broadcast_peer_message(
          swarm_id,
          "architect-lead",
          "coder-1",
          :architect,
          :architecture_spec,
          %{"step" => 2}
        )

      :timer.sleep(5)

      {:ok, msg3} =
        PeerStream.broadcast_peer_message(
          swarm_id,
          "coder-1",
          "auditor-1",
          :coder,
          :proposal_submission,
          %{"step" => 3}
        )

      history = PeerStream.get_history(swarm_id)
      assert length(history) == 3

      ids = Enum.map(history, & &1.id)
      assert ids == [msg1.id, msg2.id, msg3.id]
    end

    test "filters peer stream by role (:explorer, :architect, :coder, :auditor)", %{
      swarm_id: swarm_id
    } do
      {:ok, m_exp} =
        PeerStream.broadcast_peer_message(
          swarm_id,
          "exp",
          "arch",
          :explorer,
          :context_handoff,
          %{}
        )

      {:ok, m_arc} =
        PeerStream.broadcast_peer_message(
          swarm_id,
          "arch",
          "code",
          :architect,
          :architecture_spec,
          %{}
        )

      {:ok, m_cod} =
        PeerStream.broadcast_peer_message(
          swarm_id,
          "code",
          "aud",
          :coder,
          :proposal_submission,
          %{}
        )

      {:ok, m_aud} =
        PeerStream.broadcast_peer_message(swarm_id, "aud", "code", :auditor, :audit_critique, %{})

      history = PeerStream.get_history(swarm_id)

      explorers = PeerStream.filter_by_role(history, :explorer)
      assert length(explorers) == 1
      assert hd(explorers).id == m_exp.id

      architects = PeerStream.filter_by_role(history, :architect)
      assert length(architects) == 1
      assert hd(architects).id == m_arc.id

      coders = PeerStream.filter_by_role(history, :coder)
      assert length(coders) == 1
      assert hd(coders).id == m_cod.id

      auditors = PeerStream.filter_by_role(history, :auditor)
      assert length(auditors) == 1
      assert hd(auditors).id == m_aud.id
    end

    test "filters peer stream by agent identifier", %{swarm_id: swarm_id} do
      PeerStream.broadcast_peer_message(swarm_id, "agent-A", "agent-B", :coder, :msg, %{})
      PeerStream.broadcast_peer_message(swarm_id, "agent-B", "agent-C", :auditor, :msg, %{})
      PeerStream.broadcast_peer_message(swarm_id, "agent-C", "agent-D", :architect, :msg, %{})

      history = PeerStream.get_history(swarm_id)

      matches_a = PeerStream.filter_by_agent(history, "agent-A")
      assert length(matches_a) == 1

      matches_b = PeerStream.filter_by_agent(history, "agent-B")
      assert length(matches_b) == 2
    end

    test "clears message history completely", %{swarm_id: swarm_id} do
      PeerStream.broadcast_peer_message(swarm_id, "a", "b", :coder, :msg, %{})
      assert length(PeerStream.get_history(swarm_id)) == 1

      :ok = PeerStream.clear_history(swarm_id)
      assert PeerStream.get_history(swarm_id) == []
    end
  end
end
