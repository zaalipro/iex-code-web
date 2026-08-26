defmodule IexCodeWeb.WorkspaceComponentsTerminalLockTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias IexCodeWeb.WorkspaceComponents

  test "foreign held lock renders monitor-only terminal and disables mutating controls" do
    html =
      render_component(&WorkspaceComponents.terminal_session/1,
        session: %{id: "session-1"},
        workspace_locks: [%{status: "held", owner_id: "run:other"}],
        form: Phoenix.Component.to_form(%{"command" => ""})
      )

    document = LazyHTML.from_fragment(html)

    assert LazyHTML.query(
             document,
             "#terminal-workspace-lock-banner[data-lock-state='foreign']"
           )

    refute html =~ "run:other"

    assert LazyHTML.query(document, "#terminal-xterm-container[data-monitor-only='true']")
    assert LazyHTML.query(document, "#btn-quick-test[disabled]")
    assert LazyHTML.query(document, "#btn-terminal-restart[disabled]")
    assert LazyHTML.query(document, "#btn-terminal-kill[disabled]")
    assert LazyHTML.query(document, "#terminal-form input[disabled]")
    assert LazyHTML.query(document, "#terminal-form button[disabled]")
  end

  test "terminal's own lock does not force monitor-only mode" do
    html =
      render_component(&WorkspaceComponents.terminal_session/1,
        session: %{id: "session-1"},
        workspace_locks: [%{status: "held", owner_id: "terminal-session:session-1"}]
      )

    document = LazyHTML.from_fragment(html)
    assert document |> LazyHTML.filter("#terminal-workspace-lock-banner") |> Enum.empty?()
    assert LazyHTML.query(document, "#terminal-xterm-container[data-monitor-only='false']")
    assert document |> LazyHTML.filter("#btn-terminal-restart[disabled]") |> Enum.empty?()
  end
end
