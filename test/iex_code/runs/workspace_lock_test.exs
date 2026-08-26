defmodule IexCode.Runs.WorkspaceLockTest do
  use ExUnit.Case, async: true

  alias IexCode.Runs.WorkspaceLock

  @project_id "95d2139e-0900-42d1-a250-1d5b22aedede"
  @batch_id "46d2139e-0900-42d1-a250-1d5b22aedede"
  @hash String.duplicate("a", 64)
  @now ~U[2026-08-24 10:00:00.000000Z]

  defp changeset(overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          workspace_key: "/workspace",
          resource_type: "file",
          resource_key: "/workspace/lib/a.ex",
          batch_id: @batch_id,
          mode: "write",
          status: "held",
          owner_id: "worker:one",
          capability_token_hash: @hash,
          fencing_token: 1,
          requested_at: @now,
          acquired_at: @now,
          heartbeat_at: @now,
          lease_expires_at: DateTime.add(@now, 60, :second)
        },
        overrides
      )

    WorkspaceLock.changeset(%WorkspaceLock{project_id: @project_id}, attrs)
  end

  test "defines bounded resource, mode and lifecycle enums" do
    assert WorkspaceLock.resource_types() == ~w(project file git)
    assert WorkspaceLock.modes() == ~w(read write exclusive)
    assert WorkspaceLock.statuses() == ~w(waiting held released expired cancelled)
    assert changeset().valid?

    invalid =
      changeset(%{
        resource_type: "network",
        mode: "upgrade",
        owner_id: String.duplicate("x", 201),
        resource_key: String.duplicate("x", 4_097)
      })

    refute invalid.valid?

    for field <- ~w(resource_type mode owner_id resource_key)a,
        do: assert(field in Keyword.keys(invalid.errors))
  end

  test "waiting rows carry no lease or fence and keep durable conflict state" do
    waiting =
      changeset(%{
        status: "waiting",
        fencing_token: nil,
        acquired_at: nil,
        heartbeat_at: nil,
        lease_expires_at: DateTime.add(@now, 60, :second),
        conflict_lock_id: "36d2139e-0900-42d1-a250-1d5b22aedede",
        conflict_owner_id: "worker:blocker",
        wait_reason: "external_conflict"
      })

    assert waiting.valid?

    refute changeset(%{status: "waiting"}).valid?

    refute changeset(%{
             status: "waiting",
             fencing_token: nil,
             acquired_at: nil,
             heartbeat_at: nil,
             lease_expires_at: DateTime.add(@now, 60, :second),
             conflict_lock_id: nil,
             conflict_owner_id: nil,
             wait_reason: nil
           }).valid?
  end

  test "held leases require ordered timestamps and a positive fence" do
    invalid =
      changeset(%{
        fencing_token: 0,
        heartbeat_at: DateTime.add(@now, -1, :second),
        lease_expires_at: DateTime.add(@now, -2, :second)
      })

    refute invalid.valid?
    assert :fencing_token in Keyword.keys(invalid.errors)
    assert :heartbeat_at in Keyword.keys(invalid.errors)
    assert :lease_expires_at in Keyword.keys(invalid.errors)
  end

  test "terminal rows require a release time and clear wait conflicts" do
    refute changeset(%{status: "released"}).valid?

    assert changeset(%{status: "released", released_at: @now}).valid?
  end
end
