defmodule IexCode.Execution.ResourceGovernorWiringTest do
  use IexCode.DataCase, async: false

  alias IexCode.Execution.ResourceGovernor
  alias IexCode.Research.Fetcher
  alias IexCode.Tools.ASTSearch

  @mib 1_048_576

  test "central LLM calls queue with their interactive run metadata before provider setup" do
    governor = start_blocked_governor()
    parent = self()

    pid =
      spawn(fn ->
        result =
          IexCode.LLM.chat(
            [%{role: "user", content: "queued"}],
            "system",
            %{id: "session-17"},
            fn _chunk -> :ok end,
            resolved_route: %{
              provider: "openai",
              model: "deepseek-v4-pro",
              api_key: "not-used-while-queued",
              base_url: "https://example.com/v1",
              max_tokens: 32
            },
            resource_governor: governor,
            resource_priority: :interactive,
            resource_run_key: "interactive-run-17"
          )

        send(parent, {:llm_result, result})
      end)

    assert_pending(governor, pid, :llm_provider, :interactive, "interactive-run-17")
    Process.exit(pid, :kill)
    _ = :sys.get_state(governor)
    refute_receive {:llm_result, _result}
  end

  @tag :tmp_dir
  test "AST scans queue before discovering or reading workspace files", %{tmp_dir: root} do
    governor = start_blocked_governor()
    path = Path.join(root, "not-read.ex")
    File.write!(path, "defmodule NotRead do\nend\n")
    parent = self()

    pid =
      spawn(fn ->
        result =
          ASTSearch.search(root, %{},
            resource_governor: governor,
            resource_priority: :background,
            resource_run_key: "ast-run"
          )

        send(parent, {:ast_result, result})
      end)

    assert_pending(governor, pid, :ast_scan, :background, "ast-run")
    Process.exit(pid, :kill)
    _ = :sys.get_state(governor)
    refute_receive {:ast_result, _result}
  end

  test "each source fetch queues independently before DNS or HTTP work" do
    governor = start_blocked_governor()
    parent = self()

    pid =
      spawn(fn ->
        result =
          Fetcher.fetch("https://source.test/report",
            resource_governor: governor,
            resource_priority: :background,
            resource_run_key: "research-run",
            resolver: fn _host ->
              send(parent, :resolved)
              {:ok, [{93, 184, 216, 34}]}
            end,
            request: fn _url, _opts ->
              send(parent, :requested)
              flunk("must remain queued")
            end
          )

        send(parent, {:fetch_result, result})
      end)

    assert_pending(governor, pid, :research_fetch, :background, "research-run")
    refute_receive :resolved
    refute_receive :requested
    Process.exit(pid, :kill)
    _ = :sys.get_state(governor)
    refute_receive {:fetch_result, _result}
  end

  defp start_blocked_governor do
    start_supervised!(
      {ResourceGovernor,
       name: nil,
       read_memory: fn ->
         %{
           memory_current_bytes: 900 * @mib,
           memory_limit_bytes: 1_000 * @mib,
           pressure: %{},
           events: %{}
         }
       end,
       headroom_bytes: 0,
       poll_interval_ms: :infinity},
      id: make_ref()
    )
  end

  defp assert_pending(governor, owner, class, priority, run_key, attempts \\ 1_000)

  defp assert_pending(_governor, _owner, _class, _priority, _run_key, 0),
    do: flunk("resource request was not queued")

  defp assert_pending(governor, owner, class, priority, run_key, attempts) do
    pending = governor |> :sys.get_state() |> Map.fetch!(:pending) |> Map.values()

    if Enum.any?(pending, fn entry ->
         entry.owner == owner and entry.class == class and entry.priority == priority and
           entry.run_key == run_key
       end) do
      :ok
    else
      receive do
      after
        1 -> assert_pending(governor, owner, class, priority, run_key, attempts - 1)
      end
    end
  end
end
