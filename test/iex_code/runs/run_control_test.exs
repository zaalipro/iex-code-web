defmodule IexCode.Runs.RunControlTest do
  use ExUnit.Case, async: true

  alias IexCode.Runs.RunControl

  @run_id "95d2139e-0900-42d1-a250-1d5b22aedede"

  defp attrs(overrides) do
    Map.merge(
      %{
        idempotency_key: "ui:pause:1",
        sequence: 1,
        kind: "pause",
        payload: %{},
        requested_by: "user:local"
      },
      overrides
    )
  end

  defp changeset(overrides \\ %{}) do
    RunControl.changeset(%RunControl{run_id: @run_id}, attrs(overrides))
  end

  test "accepts each supported pending control kind" do
    for kind <- RunControl.kinds() do
      assert changeset(%{kind: kind, idempotency_key: "control:#{kind}"}).valid?
    end

    assert RunControl.statuses() == ~w(pending claimed applied rejected superseded)
    assert RunControl.terminal_statuses() == ~w(applied rejected superseded)
  end

  test "requires the durable identity, ordering, type, payload, and requester fields" do
    changeset =
      RunControl.changeset(%RunControl{}, %{
        idempotency_key: nil,
        sequence: nil,
        kind: nil,
        payload: nil,
        requested_by: nil
      })

    refute changeset.valid?

    for field <- ~w(run_id idempotency_key sequence kind payload requested_by)a do
      assert field in Keyword.keys(changeset.errors)
    end
  end

  test "rejects malformed keys, nonpositive sequences, unknown enums, and oversized actors" do
    changeset =
      changeset(%{
        idempotency_key: "contains whitespace",
        sequence: 0,
        kind: "rewind",
        status: "lost",
        requested_by: String.duplicate("r", 161)
      })

    refute changeset.valid?

    for field <- ~w(idempotency_key sequence kind status requested_by)a do
      assert field in Keyword.keys(changeset.errors)
    end
  end

  test "declares per-run uniqueness and run foreign-key constraints" do
    changeset = changeset()

    assert %{type: :unique} =
             Enum.find(
               changeset.constraints,
               &(&1.constraint == "run_controls_run_id_idempotency_key_index")
             )

    assert %{type: :unique} =
             Enum.find(
               changeset.constraints,
               &(&1.constraint == "run_controls_run_id_sequence_index")
             )

    assert %{type: :foreign_key} =
             Enum.find(changeset.constraints, &(&1.field == :run_id))
  end

  test "claimed controls require a worker claim and cannot contain an outcome" do
    invalid = changeset(%{status: "claimed", result: %{"ok" => true}})

    refute invalid.valid?
    assert :worker_id in Keyword.keys(invalid.errors)
    assert :claimed_at in Keyword.keys(invalid.errors)
    assert :result in Keyword.keys(invalid.errors)

    now = ~U[2026-08-24 10:00:00Z]

    assert changeset(%{
             status: "claimed",
             worker_id: "dispatcher:1",
             claim_generation: 0,
             claimed_at: now,
             claim_expires_at: DateTime.add(now, 30, :second)
           }).valid?
  end

  test "applied and rejected outcomes require a complete worker claim and durable result" do
    now = ~U[2026-08-24 10:00:00Z]

    for status <- ~w(applied rejected) do
      invalid = changeset(%{status: status})
      refute invalid.valid?

      for field <- ~w(worker_id claim_generation claimed_at claim_expires_at applied_at result)a do
        assert field in Keyword.keys(invalid.errors)
      end

      assert changeset(%{
               status: status,
               worker_id: "dispatcher:1",
               claim_generation: 0,
               claimed_at: now,
               claim_expires_at: DateTime.add(now, 30, :second),
               applied_at: now,
               result: %{"outcome" => status}
             }).valid?
    end
  end

  test "a control can be superseded before or after claim but requires a recorded outcome" do
    now = ~U[2026-08-24 10:00:00Z]

    assert changeset(%{
             status: "superseded",
             applied_at: now,
             result: %{"by_sequence" => 2}
           }).valid?

    invalid =
      changeset(%{
        status: "superseded",
        worker_id: "dispatcher:1",
        claim_generation: 0,
        applied_at: now,
        result: %{"by_sequence" => 2}
      })

    refute invalid.valid?

    for field <- ~w(claimed_at claim_expires_at)a do
      assert field in Keyword.keys(invalid.errors)
    end
  end

  test "pending controls reject claim and outcome data" do
    now = ~U[2026-08-24 10:00:00Z]

    changeset =
      changeset(%{
        worker_id: "dispatcher:1",
        claim_generation: 0,
        claimed_at: now,
        claim_expires_at: DateTime.add(now, 30, :second),
        applied_at: now,
        result: %{"ok" => true}
      })

    refute changeset.valid?

    for field <- ~w(worker_id claim_generation claimed_at claim_expires_at applied_at result)a do
      assert field in Keyword.keys(changeset.errors)
    end
  end

  test "an outcome cannot predate its claim" do
    changeset =
      changeset(%{
        status: "applied",
        worker_id: "dispatcher:1",
        claim_generation: 0,
        claimed_at: ~U[2026-08-24 10:00:01Z],
        claim_expires_at: ~U[2026-08-24 10:00:30Z],
        applied_at: ~U[2026-08-24 10:00:00Z],
        result: %{"ok" => true}
      })

    refute changeset.valid?
    assert {"cannot be before claimed_at", _metadata} = changeset.errors[:applied_at]
  end

  test "a claim expiry must be after its claim timestamp" do
    changeset =
      changeset(%{
        status: "claimed",
        worker_id: "dispatcher:1",
        claim_generation: 0,
        claimed_at: ~U[2026-08-24 10:00:01Z],
        claim_expires_at: ~U[2026-08-24 10:00:01Z]
      })

    refute changeset.valid?
    assert {"must be after claimed_at", _metadata} = changeset.errors[:claim_expires_at]
  end

  test "a worker claim is fenced to the control target generation" do
    changeset =
      changeset(%{
        target_generation: 4,
        status: "claimed",
        worker_id: "dispatcher:1",
        claim_generation: 3,
        claimed_at: ~U[2026-08-24 10:00:01Z],
        claim_expires_at: ~U[2026-08-24 10:00:30Z]
      })

    refute changeset.valid?

    assert {"must match target_generation", _metadata} =
             changeset.errors[:claim_generation]
  end
end
