defmodule IexCode.Runs.ExecutorLegacySwarmCompatibilityTest do
  use IexCode.DataCase, async: false

  alias IexCode.E2E.MockLLMServer
  alias IexCode.Engine.FleetSupervisor
  alias IexCode.Runs.Executor
  alias IexCode.{Projects, Runs, Sessions, Settings}

  setup do
    root = Path.join(System.tmp_dir!(), "legacy-swarm-#{Ecto.UUID.generate()}")
    File.mkdir_p!(root)

    {:ok, project} =
      Projects.create_project(%{name: "Legacy swarm compatibility", root_path: root})

    {:ok, session} =
      Sessions.create_session(%{
        project_id: project.id,
        title: "Legacy swarm compatibility",
        model_provider: "openai",
        model_name: "legacy-live-session-model",
        temperature: 0.35
      })

    {:ok, mock_pid, mock_info} = MockLLMServer.start(scenario: :standard_completion)

    assert {:ok, _settings} =
             Settings.update_settings(%{
               openai_base_url: "#{mock_info.url}/v1",
               openai_api_key: "legacy-live-route-key"
             })

    on_exit(fn ->
      MockLLMServer.stop(mock_pid)
      File.rm_rf(root)
    end)

    %{project: project, session: session, root: root, mock_pid: mock_pid}
  end

  test "queued legacy swarm without an execution-policy snapshot uses its live session route",
       ctx do
    run = create_and_claim_legacy_swarm(ctx, "queued legacy swarm")
    on_exit(fn -> FleetSupervisor.stop(run.id) end)

    refute Map.has_key?(run.metadata || %{}, "execution_policy")
    assert {:ok, _result} = execute(run)

    requests = MockLLMServer.get_requests(ctx.mock_pid)
    assert length(requests) >= 2
    assert Enum.all?(requests, &(&1.path == "/v1/chat/completions"))
    assert Enum.all?(requests, &(&1.body["model"] == "legacy-live-session-model"))
  end

  test "retried legacy swarm preserves the missing snapshot compatibility path", ctx do
    first_attempt = create_and_claim_legacy_swarm(ctx, "retried legacy swarm", max_attempts: 2)
    on_exit(fn -> FleetSupervisor.stop(first_attempt.id) end)

    assert {:ok, failed} =
             Runs.finalize_run_worker(first_attempt, "failed", %{}, authority(first_attempt))

    assert {:ok, queued_retry} = Runs.retry_run(failed)
    refute Map.has_key?(queued_retry.metadata || %{}, "execution_policy")

    retry_owner = "legacy-swarm-retry:#{System.unique_integer([:positive])}"
    assert {:ok, retry} = Runs.claim_next_run(retry_owner, lease_ms: 300_000)
    assert retry.id == first_attempt.id
    assert retry.attempt == 2

    assert {:ok, _result} = execute(retry)

    requests = MockLLMServer.get_requests(ctx.mock_pid)
    assert length(requests) >= 2
    assert Enum.all?(requests, &(&1.body["model"] == "legacy-live-session-model"))
  end

  defp create_and_claim_legacy_swarm(ctx, objective, opts \\ []) do
    assert {:ok, _queued} =
             Runs.create_run(%{
               project_id: ctx.project.id,
               session_id: ctx.session.id,
               objective: objective,
               kind: "coding_swarm",
               mode: "swarm",
               execution_engine: "legacy_v1",
               max_attempts: Keyword.get(opts, :max_attempts, 1),
               metadata: %{"legacy_origin" => true}
             })

    owner = "legacy-swarm:#{System.unique_integer([:positive])}"
    assert {:ok, run} = Runs.claim_next_run(owner, lease_ms: 300_000)
    run
  end

  defp execute(run) do
    Executor.execute(run, fn _percent, _message -> :ok end,
      run_lease_owner: run.lease_owner,
      run_attempt: run.attempt,
      run_lease_generation: run.lease_generation,
      run_lease_ms: 300_000,
      run_terminal_lease_ms: 30_000
    )
  end

  defp authority(run) do
    [
      lease_owner: run.lease_owner,
      run_attempt: run.attempt,
      lease_generation: run.lease_generation,
      terminal_lease_ms: 30_000
    ]
  end
end
