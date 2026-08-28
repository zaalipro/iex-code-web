defmodule IexCodeWeb.InstrumentSummaryTest do
  use ExUnit.Case, async: true

  alias IexCodeWeb.InstrumentSummary

  @surfaces ~w(kanban swarm research calendar changes chat files terminal)
  @statuses [:ready, :active, :attention, :empty, :error, :standby]
  @summary_keys ~w(surface title status primary secondary detail destination updated_at attention?)a

  defp facts(destination \\ "/sessions/session-id") do
    %{destination: destination}
  end

  defp assert_closed_summary(summary) do
    assert Map.keys(summary) |> Enum.sort() == Enum.sort(@summary_keys)
    assert summary.surface in @surfaces
    assert summary.status in @statuses
    assert is_binary(summary.destination)
    assert summary.attention? == summary.status in [:attention, :error]
    assert is_nil(summary.updated_at) or match?(%DateTime{}, summary.updated_at)

    for value <- [summary.primary, summary.detail] do
      assert is_nil(value) or is_binary(value)

      if is_binary(value) do
        assert String.valid?(value)
        assert String.length(value) <= 160
      end
    end

    assert is_list(summary.secondary)

    for secondary <- summary.secondary do
      assert Map.keys(secondary) |> Enum.sort() == [:label, :value]
      assert is_binary(secondary.label)
      assert is_binary(secondary.value)
      assert String.valid?(secondary.value)
      assert String.length(secondary.value) <= 160
    end

    summary
  end

  test "build dispatches the closed surface set and preserves internal destinations" do
    inputs = [
      {"kanban", %{status_counts: %{}, today_count: 0, next_scheduled_at: nil}},
      {"swarm", %{run: nil, phase: nil, progress: nil, pending_approvals: 0}},
      {"research",
       %{run: nil, level: nil, completed_round: nil, source_count: 0, result_ready?: false}},
      {"calendar", %{status_counts: %{}, today_count: 0, next_scheduled_at: nil}},
      {"changes", %{git_status: nil, git_error: nil, latest_test: nil}},
      {"chat", %{latest_message: nil, messages_newer?: false}},
      {"files",
       %{
         loaded?: false,
         file_count: 0,
         files_more?: false,
         selected_file: nil,
         dirty?: false,
         git_relation: nil
       }},
      {"terminal",
       %{available?: false, state: nil, active_command: nil, latest_command: nil, owner: nil}}
    ]

    for {surface, surface_facts} <- inputs do
      destination = "/sessions/trusted/#{surface}"

      summary =
        surface
        |> InstrumentSummary.build(Map.merge(surface_facts, facts(destination)))
        |> assert_closed_summary()

      assert summary.surface == surface
      assert summary.destination == destination
    end
  end

  test "build rejects every unsupported surface without atom conversion" do
    for surface <- ["deck", "KANBAN", :kanban, nil, 17, %{}] do
      assert_raise ArgumentError, fn -> InstrumentSummary.build(surface, facts()) end
    end
  end

  test "requires the trusted route destination instead of inventing root navigation" do
    assert_raise ArgumentError, fn ->
      InstrumentSummary.board(%{status_counts: %{}})
    end
  end

  describe "mission/1" do
    test "uses exact empty fallback" do
      summary =
        InstrumentSummary.mission(Map.merge(facts(), %{run: nil})) |> assert_closed_summary()

      assert summary.title == "Active Mission"
      assert summary.status == :empty
      assert summary.primary == "No active run"
      assert summary.secondary == []
      assert summary.detail == nil
      assert summary.updated_at == nil
    end

    test "reports active progress and review while bounding run text" do
      updated_at = ~U[2026-08-28 10:00:00Z]
      objective = String.duplicate("∆", 170) <> <<255>>
      phase = String.duplicate("phase-", 40) <> <<255>>

      summary =
        InstrumentSummary.mission(%{
          destination: "/sessions/s?view=swarm",
          run: %{
            objective: objective,
            status: "running",
            updated_at: updated_at,
            lease_owner: "LEASE-SECRET"
          },
          phase: phase,
          progress: 130,
          pending_approvals: 2
        })
        |> assert_closed_summary()

      assert summary.status == :attention
      assert summary.updated_at == updated_at
      assert summary.primary |> String.length() == 160
      assert summary.detail |> String.length() == 160

      assert summary.secondary == [
               %{label: "Progress", value: "100%"},
               %{label: "Review", value: "2 pending approvals"}
             ]

      refute inspect(summary) =~ "LEASE-SECRET"
    end

    test "maps terminal and waiting run states truthfully" do
      cases = [
        {"running", :active},
        {"paused", :attention},
        {"queued", :standby},
        {"draft", :standby},
        {"completed", :ready},
        {"cancelled", :empty},
        {"failed", :attention},
        {"interrupted", :attention},
        {"unknown", :standby}
      ]

      for {run_status, expected_status} <- cases do
        summary =
          InstrumentSummary.mission(%{
            destination: "/?view=swarm",
            run: %{objective: "Mission", status: run_status},
            phase: nil,
            progress: -4,
            pending_approvals: 0
          })
          |> assert_closed_summary()

        assert summary.status == expected_status
        assert summary.detail == "Status: #{run_status}"

        assert summary.secondary == [
                 %{label: "Progress", value: "0%"},
                 %{label: "Review", value: "No pending approvals"}
               ]
      end
    end

    test "uses the status fallback for a blank phase" do
      summary =
        InstrumentSummary.mission(%{
          destination: "/?view=swarm",
          run: %{objective: "Mission", status: "running"},
          phase: "   ",
          progress: 50,
          pending_approvals: 0
        })

      assert summary.detail == "Status: running"
    end
  end

  describe "board/1" do
    test "uses exact unavailable and empty fallbacks" do
      unavailable =
        InstrumentSummary.board(Map.merge(facts(), %{error?: true})) |> assert_closed_summary()

      assert unavailable.status == :error
      assert unavailable.primary == "Board unavailable"
      assert unavailable.secondary == []

      empty =
        InstrumentSummary.board(
          Map.merge(facts(), %{status_counts: %{"todo" => -1, "unknown" => 99}})
        )
        |> assert_closed_summary()

      assert empty.status == :empty
      assert empty.primary == "No tasks yet"
      assert Enum.map(empty.secondary, & &1.value) == List.duplicate("0", 8)
    end

    test "returns all known counts in closed order and status precedence" do
      running =
        InstrumentSummary.board(%{
          destination: "/sessions/s?view=kanban",
          status_counts: %{"todo" => 2, "running" => 1, "blocked" => "secret", "unknown" => 900}
        })
        |> assert_closed_summary()

      assert running.status == :active
      assert running.primary == "3 tasks"

      assert Enum.map(running.secondary, & &1.label) == [
               "Triage",
               "Todo",
               "Scheduled",
               "Ready",
               "Running",
               "Blocked",
               "Review",
               "Done"
             ]

      assert Enum.map(running.secondary, & &1.value) == ["0", "2", "0", "0", "1", "0", "0", "0"]

      blocked =
        InstrumentSummary.board(%{
          destination: "/?view=kanban",
          status_counts: %{"blocked" => 1, "running" => 4}
        })
        |> assert_closed_summary()

      assert blocked.status == :attention
      assert blocked.primary == "5 tasks"
    end
  end

  describe "schedule/1" do
    test "uses exact unavailable and no-action fallbacks" do
      unavailable =
        InstrumentSummary.schedule(Map.merge(facts(), %{error?: true})) |> assert_closed_summary()

      assert unavailable.status == :error
      assert unavailable.primary == "Schedule unavailable"
      assert unavailable.secondary == []

      empty =
        InstrumentSummary.schedule(Map.merge(facts(), %{today_count: -5, next_scheduled_at: nil}))
        |> assert_closed_summary()

      assert empty.status == :empty
      assert empty.primary == "No scheduled actions"
      assert empty.secondary == [%{label: "Today", value: "0 today"}]
    end

    test "distinguishes today and next scheduled actions" do
      next_at = ~U[2026-08-29 09:30:00Z]

      future =
        InstrumentSummary.schedule(%{
          destination: "/?view=calendar",
          today_count: 0,
          next_scheduled_at: next_at
        })
        |> assert_closed_summary()

      assert future.status == :ready
      assert future.primary == "Next · 2026-08-29T09:30:00Z"

      today =
        InstrumentSummary.schedule(%{
          destination: "/?view=calendar",
          today_count: 3,
          next_scheduled_at: nil
        })
        |> assert_closed_summary()

      assert today.status == :active
      assert today.primary == "No scheduled actions"
      assert today.secondary == [%{label: "Today", value: "3 today"}]
    end
  end

  describe "research/1" do
    test "uses exact no-run fallback" do
      summary =
        InstrumentSummary.research(Map.merge(facts("/sessions/s/research"), %{run: nil}))
        |> assert_closed_summary()

      assert summary.status == :empty
      assert summary.primary == "No research runs"
      assert summary.secondary == []
      assert summary.detail == nil
    end

    test "normalizes research facts and clamps rounds" do
      summary =
        InstrumentSummary.research(%{
          destination: "/research",
          run: %{
            objective: "Investigate",
            status: "running",
            updated_at: ~U[2026-08-28 11:00:00Z],
            metadata: %{"secret" => "RUN-METADATA-SECRET"}
          },
          level: "ultra",
          completed_round: 99,
          source_count: -3,
          result_ready?: false
        })
        |> assert_closed_summary()

      assert summary.status == :active
      assert summary.detail == "Research running"

      assert summary.secondary == [
               %{label: "Level", value: "Ultra"},
               %{label: "Round", value: "4/4 complete"},
               %{label: "Sources", value: "0"},
               %{label: "Result", value: "Pending"}
             ]

      refute inspect(summary) =~ "RUN-METADATA-SECRET"
    end

    test "maps waiting, ready, attention, and empty states" do
      cases = [
        {"queued", false, :standby},
        {"draft", false, :standby},
        {"paused", false, :standby},
        {"completed", true, :ready},
        {"completed", false, :standby},
        {"failed", false, :attention},
        {"interrupted", false, :attention},
        {"cancelled", false, :empty}
      ]

      for {run_status, ready?, expected_status} <- cases do
        summary =
          InstrumentSummary.research(%{
            destination: "/research",
            run: %{objective: "Research", status: run_status},
            level: "unexpected",
            completed_round: nil,
            source_count: 5,
            result_ready?: ready?
          })
          |> assert_closed_summary()

        assert summary.status == expected_status
        assert hd(summary.secondary) == %{label: "Level", value: "Medium"}
        assert Enum.at(summary.secondary, 1) == %{label: "Round", value: "0/2 complete"}
      end
    end
  end

  describe "changes/1" do
    test "uses warming, unavailable, and clean fallbacks without leaking errors" do
      warming =
        InstrumentSummary.changes(%{
          destination: "/?view=changes",
          git_status: nil,
          git_error: nil,
          latest_test: nil
        })
        |> assert_closed_summary()

      assert warming.status == :standby
      assert warming.primary == "Warming · checking Git"

      unavailable =
        InstrumentSummary.changes(%{
          destination: "/?view=changes",
          git_status: nil,
          git_error: {:secret, "GIT-ERROR-SECRET"},
          latest_test: nil
        })
        |> assert_closed_summary()

      assert unavailable.status == :error
      assert unavailable.primary == "Git unavailable"
      assert unavailable.secondary == []
      refute inspect(unavailable) =~ "GIT-ERROR-SECRET"

      clean =
        InstrumentSummary.changes(%{
          destination: "/?view=changes",
          git_status: %{
            branch: "main",
            staged: [],
            unstaged: [],
            untracked: [],
            conflicted: [],
            clean?: true,
            truncated?: false
          },
          git_error: nil,
          latest_test: nil
        })
        |> assert_closed_summary()

      assert clean.status == :ready
      assert clean.primary == "No changes"
      assert List.last(clean.secondary) == %{label: "Tests", value: "No test operation recorded"}
    end

    test "reports only bounded counts, branch, and latest test scalars" do
      summary =
        InstrumentSummary.changes(%{
          destination: "/sessions/s?view=changes",
          git_status: %{
            branch: String.duplicate("branch", 40),
            staged: [%{path: "PATH-SECRET-STAGED"}],
            unstaged: [%{path: "PATH-SECRET-UNSTAGED"}],
            untracked: ["PATH-SECRET-UNTRACKED"],
            conflicted: [%{path: "PATH-SECRET-CONFLICT"}],
            clean?: false,
            truncated?: true
          },
          git_error: nil,
          latest_test: %{
            status: "completed",
            duration_ms: 125,
            pid_str: "PID-SECRET",
            params: %{"password" => "PARAM-SECRET"},
            result: "RESULT-SECRET",
            error_message: "OP-ERROR-SECRET"
          }
        })
        |> assert_closed_summary()

      assert summary.status == :attention
      assert summary.primary == "4 changes"
      assert summary.detail == "Showing bounded Git status"

      assert Enum.find(summary.secondary, &(&1.label == "Latest test operation")) == %{
               label: "Latest test operation",
               value: "completed · 125 ms"
             }

      for secret <- ~w(PATH-SECRET PID-SECRET PARAM-SECRET RESULT-SECRET OP-ERROR-SECRET) do
        refute inspect(summary) =~ secret
      end
    end

    test "marks ordinary changes active and omits absent duration" do
      summary =
        InstrumentSummary.changes(%{
          destination: "/?view=changes",
          git_status: %{
            branch: "dev",
            staged: [:entry],
            unstaged: [],
            untracked: [],
            conflicted: [],
            clean?: false,
            truncated?: false
          },
          git_error: nil,
          latest_test: %{status: "failed", duration_ms: nil}
        })
        |> assert_closed_summary()

      assert summary.status == :active
      assert summary.primary == "1 change"
      assert List.last(summary.secondary) == %{label: "Latest test operation", value: "failed"}
    end
  end

  describe "chat/1" do
    test "uses exact empty fallback" do
      summary =
        InstrumentSummary.chat(Map.merge(facts(), %{latest_message: nil, messages_newer?: true}))
        |> assert_closed_summary()

      assert summary.status == :empty
      assert summary.primary == "No messages yet"
      assert summary.secondary == []
    end

    test "projects only durable message summary fields and bounds content" do
      sent_at = ~U[2026-08-28 12:34:56Z]

      summary =
        InstrumentSummary.chat(%{
          destination: "/sessions/s?view=chat",
          latest_message: %{
            content: String.duplicate("🙂", 165) <> <<255>>,
            role: "assistant",
            agent_name: "Verifier",
            inserted_at: sent_at,
            metadata: %{"token" => "MESSAGE-METADATA-SECRET"},
            tool_calls: [%{"secret" => "TOOL-CALL-SECRET"}]
          },
          messages_newer?: true
        })
        |> assert_closed_summary()

      assert summary.status == :ready
      assert String.length(summary.primary) == 160
      assert summary.updated_at == sent_at

      assert summary.secondary == [
               %{label: "From", value: "Verifier"},
               %{label: "Sent", value: "2026-08-28T12:34:56Z"},
               %{label: "History", value: "Newer messages available"}
             ]

      refute inspect(summary) =~ "MESSAGE-METADATA-SECRET"
      refute inspect(summary) =~ "TOOL-CALL-SECRET"
    end
  end

  describe "files/1" do
    test "uses exact unloaded and empty fallbacks" do
      unloaded =
        InstrumentSummary.files(
          Map.merge(facts(), %{loaded?: false, file_count: 500, dirty?: true})
        )
        |> assert_closed_summary()

      assert unloaded.status == :standby
      assert unloaded.primary == "Standby · files not loaded"
      assert unloaded.secondary == []

      empty =
        InstrumentSummary.files(
          Map.merge(facts(), %{
            loaded?: true,
            file_count: 0,
            files_more?: false,
            selected_file: nil,
            dirty?: false,
            git_relation: nil
          })
        )
        |> assert_closed_summary()

      assert empty.status == :empty
      assert empty.primary == "No files discovered"

      assert empty.secondary == [
               %{label: "Selected", value: "No file selected"},
               %{label: "Buffer", value: "Saved"}
             ]
    end

    test "reports retained bound, selected buffer, dirty attention, and bounded relation" do
      summary =
        InstrumentSummary.files(%{
          destination: "/sessions/s?view=files",
          loaded?: true,
          file_count: 500,
          files_more?: true,
          selected_file: String.duplicate("lib/文件/", 40),
          dirty?: true,
          git_relation: String.duplicate("Modified · ", 30)
        })
        |> assert_closed_summary()

      assert summary.status == :attention
      assert summary.primary == "500+ files indexed"
      assert Enum.at(summary.secondary, 1) == %{label: "Buffer", value: "Unsaved changes"}
      assert Enum.find(summary.secondary, &(&1.label == "Git")).value |> String.length() == 160
    end

    test "marks a selected saved file active and an unselected atlas ready" do
      selected =
        InstrumentSummary.files(%{
          destination: "/?view=files",
          loaded?: true,
          file_count: 1,
          files_more?: false,
          selected_file: "README.md",
          dirty?: false,
          git_relation: nil
        })
        |> assert_closed_summary()

      assert selected.status == :active
      assert selected.primary == "1 file indexed"

      ready =
        InstrumentSummary.files(%{
          destination: "/?view=files",
          loaded?: true,
          file_count: 2,
          files_more?: false,
          selected_file: nil,
          dirty?: false,
          git_relation: nil
        })
        |> assert_closed_summary()

      assert ready.status == :ready
      assert ready.primary == "2 files indexed"
    end
  end

  describe "terminal/1" do
    test "uses exact unavailable and idle fallbacks" do
      unavailable =
        InstrumentSummary.terminal(Map.merge(facts(), %{available?: false}))
        |> assert_closed_summary()

      assert unavailable.status == :error
      assert unavailable.primary == "Terminal unavailable"
      assert unavailable.secondary == []

      idle =
        InstrumentSummary.terminal(%{
          destination: "/?view=terminal",
          available?: true,
          state: :ready,
          active_command: nil,
          latest_command: nil,
          owner: :user
        })
        |> assert_closed_summary()

      assert idle.status == :ready
      assert idle.primary == "No command yet"
      assert idle.detail == "Idle · no active command"

      assert idle.secondary == [
               %{label: "State", value: "Ready"},
               %{label: "Owner", value: "User"}
             ]
    end

    test "active command wins and agent operation identity is never disclosed" do
      summary =
        InstrumentSummary.terminal(%{
          destination: "/sessions/s?view=terminal",
          available?: true,
          state: :running,
          active_command: "mix test",
          latest_command: %{
            command: "old command",
            status: "failed",
            exit_code: 7,
            id: "COMMAND-ID-SECRET"
          },
          owner: {:agent, String.duplicate("Verifier", 30), "OP-ID-SECRET"},
          os_pid: "OS-PID-SECRET"
        })
        |> assert_closed_summary()

      assert summary.status == :active
      assert summary.primary == "mix test"
      assert summary.detail == "Command active"

      assert Enum.find(summary.secondary, &(&1.label == "Exit")) == %{
               label: "Exit",
               value: "Failed · exit 7"
             }

      refute inspect(summary) =~ "old command"

      for secret <- ~w(COMMAND-ID-SECRET OP-ID-SECRET OS-PID-SECRET) do
        refute inspect(summary) =~ secret
      end
    end

    test "uses latest command when idle and maps stopped and error states" do
      stopped =
        InstrumentSummary.terminal(%{
          destination: "/?view=terminal",
          available?: true,
          state: "stopped",
          active_command: "",
          latest_command: "pwd",
          owner: {:agent, nil, "secret"}
        })
        |> assert_closed_summary()

      assert stopped.status == :standby
      assert stopped.primary == "pwd"

      assert stopped.secondary == [
               %{label: "State", value: "Stopped"},
               %{label: "Owner", value: "Agent"}
             ]

      errored =
        InstrumentSummary.terminal(%{
          destination: "/?view=terminal",
          available?: true,
          state: :error,
          active_command: nil,
          latest_command: nil,
          owner: nil
        })
        |> assert_closed_summary()

      assert errored.status == :error
    end
  end
end
