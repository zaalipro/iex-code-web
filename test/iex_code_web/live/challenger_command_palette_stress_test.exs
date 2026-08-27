defmodule IexCodeWeb.ChallengerCommandPaletteStressTest do
  use IexCode.E2E.Case, async: false

  @moduletag mock_llm: true

  alias IexCodeWeb.CommandPalette

  describe "CommandPalette.search/3" do
    setup do
      sessions = [
        %{id: "sess-1", title: "Authentication Flow", updated_at: DateTime.utc_now()},
        %{id: "sess-2", title: "Calculator Refactor", updated_at: ~N[2026-08-22 10:00:00]},
        %{id: "sess-3", title: nil, updated_at: nil}
      ]

      {:ok, sessions: sessions}
    end

    test "handles empty and adversarial queries", %{sessions: sessions} do
      for query <- [
            nil,
            "",
            "   \t\n",
            "[",
            "]",
            "*",
            "+",
            "?",
            "\\",
            String.duplicate("x", 100_000)
          ] do
        assert is_list(CommandPalette.search(query, sessions, "all"))
      end
    end

    test "isolates supported categories and rejects removed file indexing", %{sessions: sessions} do
      assert Enum.all?(CommandPalette.search("", sessions, "actions"), &(&1.category == :action))
      assert Enum.all?(CommandPalette.search("", sessions, "views"), &(&1.category == :view))

      session_results = CommandPalette.search("calculator", sessions, "sessions")
      assert Enum.map(session_results, & &1.title) == ["Calculator Refactor"]

      assert CommandPalette.search("anything", sessions, "files") == []
      assert CommandPalette.search("anything", sessions, "unknown") == []
    end

    test "caps session results at ten" do
      sessions = for i <- 1..20, do: %{id: "s#{i}", title: "Session #{i}"}
      assert length(CommandPalette.search("session", sessions, "sessions")) == 10
    end

    test "removed browser studios are absent from actions and views" do
      ids =
        Enum.map(CommandPalette.actions(), & &1.id) ++ Enum.map(CommandPalette.views(), & &1.id)

      refute "run_all_tests" in ids
      refute "run_failed_tests" in ids
      refute "run_stale_tests" in ids
      refute "trigger_autofix" in ids
      refute "ast_search" in ids
      refute "view_tests" in ids
      refute "view_ast" in ids
    end
  end
end
