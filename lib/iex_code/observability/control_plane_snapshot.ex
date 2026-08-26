defmodule IexCode.Observability.ControlPlaneSnapshot do
  @moduledoc false

  import Ecto.Query, warn: false

  alias IexCode.Repo

  alias IexCode.Runs.{
    Run,
    RunAgent,
    RunAgentControl,
    RunApproval,
    RunControl,
    RunStepAttempt,
    WorkspaceLock
  }

  @spec build(DateTime.t()) :: %{required(atom()) => non_neg_integer()}
  def build(now \\ DateTime.utc_now()) do
    # Keep periodic collection bounded to one aggregate query per table. No
    # durable row or identifier is loaded into the metrics process.
    Map.merge(run_counts(now), agent_counts(now))
    |> Map.merge(attempt_counts(now))
    |> Map.merge(control_counts())
    |> Map.merge(approval_counts(now))
    |> Map.merge(lock_counts(now))
  end

  defp run_counts(now) do
    attention_since = DateTime.add(now, -86_400, :second)

    Repo.one!(
      from run in Run,
        where:
          run.status in ["queued", "running", "paused"] or
            (run.status in ["failed", "interrupted"] and run.updated_at >= ^attention_since),
        select: %{
          runs_queued:
            fragment("COALESCE(SUM(CASE WHEN ? = 'queued' THEN 1 ELSE 0 END), 0)", run.status),
          runs_active:
            fragment(
              "COALESCE(SUM(CASE WHEN ? IN ('running','paused') THEN 1 ELSE 0 END), 0)",
              run.status
            ),
          runs_attention:
            fragment(
              "COALESCE(SUM(CASE WHEN ? IN ('failed','interrupted') THEN 1 ELSE 0 END), 0)",
              run.status
            ),
          runs_expired_leases:
            fragment(
              "COALESCE(SUM(CASE WHEN ? IN ('running','paused') AND (? IS NULL OR ? <= ?) THEN 1 ELSE 0 END), 0)",
              run.status,
              run.lease_expires_at,
              run.lease_expires_at,
              ^now
            )
        }
    )
  end

  defp agent_counts(now) do
    attention_since = DateTime.add(now, -86_400, :second)

    Repo.one!(
      from agent in RunAgent,
        where:
          agent.status in ["starting", "idle", "running", "paused", "stopping"] or
            (agent.status in ["failed", "interrupted"] and agent.updated_at >= ^attention_since),
        select: %{
          agents_active:
            fragment(
              "COALESCE(SUM(CASE WHEN ? IN ('starting','idle','running','stopping') THEN 1 ELSE 0 END), 0)",
              agent.status
            ),
          agents_paused:
            fragment(
              "COALESCE(SUM(CASE WHEN ? = 'paused' THEN 1 ELSE 0 END), 0)",
              agent.status
            ),
          agents_attention:
            fragment(
              "COALESCE(SUM(CASE WHEN ? IN ('failed','interrupted') THEN 1 ELSE 0 END), 0)",
              agent.status
            ),
          agents_expired_leases:
            fragment(
              "COALESCE(SUM(CASE WHEN ? IN ('starting','idle','running','paused','stopping') AND (? IS NULL OR ? <= ?) THEN 1 ELSE 0 END), 0)",
              agent.status,
              agent.lease_expires_at,
              agent.lease_expires_at,
              ^now
            )
        }
    )
  end

  defp attempt_counts(now) do
    Repo.one!(
      from attempt in RunStepAttempt,
        where: attempt.status in ["running", "paused"],
        select: %{
          dag_attempts_active:
            fragment(
              "COALESCE(SUM(CASE WHEN ? IN ('running','paused') THEN 1 ELSE 0 END), 0)",
              attempt.status
            ),
          dag_attempts_expired_leases:
            fragment(
              "COALESCE(SUM(CASE WHEN ? IN ('running','paused') AND (? IS NULL OR ? <= ?) THEN 1 ELSE 0 END), 0)",
              attempt.status,
              attempt.lease_expires_at,
              attempt.lease_expires_at,
              ^now
            )
        }
    )
  end

  defp control_counts do
    run_controls =
      Repo.one!(
        from control in RunControl,
          where: control.status in ["pending", "claimed"],
          select: %{
            run_controls_open:
              fragment(
                "COALESCE(SUM(CASE WHEN ? IN ('pending','claimed') THEN 1 ELSE 0 END), 0)",
                control.status
              )
          }
      )

    agent_controls =
      Repo.one!(
        from control in RunAgentControl,
          where: control.status in ["pending", "claimed"],
          select: %{
            agent_controls_open:
              fragment(
                "COALESCE(SUM(CASE WHEN ? IN ('pending','claimed') THEN 1 ELSE 0 END), 0)",
                control.status
              )
          }
      )

    Map.merge(run_controls, agent_controls)
  end

  defp approval_counts(now) do
    Repo.one!(
      from approval in RunApproval,
        where: approval.status == "pending",
        select: %{
          approvals_pending:
            fragment(
              "COALESCE(SUM(CASE WHEN ? = 'pending' THEN 1 ELSE 0 END), 0)",
              approval.status
            ),
          approvals_overdue:
            fragment(
              "COALESCE(SUM(CASE WHEN ? = 'pending' AND ? IS NOT NULL AND ? <= ? THEN 1 ELSE 0 END), 0)",
              approval.status,
              approval.expires_at,
              approval.expires_at,
              ^now
            )
        }
    )
  end

  defp lock_counts(now) do
    Repo.one!(
      from lock in WorkspaceLock,
        where: lock.status in ["held", "waiting"],
        select: %{
          workspace_locks_held:
            fragment(
              "COALESCE(SUM(CASE WHEN ? = 'held' THEN 1 ELSE 0 END), 0)",
              lock.status
            ),
          workspace_locks_waiting:
            fragment(
              "COALESCE(SUM(CASE WHEN ? = 'waiting' THEN 1 ELSE 0 END), 0)",
              lock.status
            ),
          workspace_locks_expired:
            fragment(
              "COALESCE(SUM(CASE WHEN ? IN ('held','waiting') AND (? IS NULL OR ? <= ?) THEN 1 ELSE 0 END), 0)",
              lock.status,
              lock.lease_expires_at,
              lock.lease_expires_at,
              ^now
            )
        }
    )
  end
end
