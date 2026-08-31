defmodule IexCodeWeb.WorkspaceComponentsWorkbenchTest do
  use IexCode.E2E.Case, async: true
  import Phoenix.Component
  import Phoenix.LiveViewTest
  import IexCodeWeb.WorkspaceComponents

  test "renders the frozen chassis identity, return patch, and slots in order" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <.workbench_chassis
        id="instrument-workbench-chat"
        surface="chat"
        index="06"
        title="Conversation Loop"
        status="Ready"
        return_to="/sessions/session-1"
        return_instrument_id="instrument-card-chat"
      >
        <:primary_action><button id="primary-one">Launch</button></:primary_action>
        <:primary_action><button id="primary-two">Duplicate</button></:primary_action>
        <:local_modes>
          <div id="mode-tabs">Modes</div>
        </:local_modes>
        <:primary_field>
          <div id="primary-field">Field</div>
        </:primary_field>
        <:signal_panel>
          <aside id="signal-panel">Signal</aside>
        </:signal_panel>
        <:command_dock>
          <div id="command-dock">Dock</div>
        </:command_dock>
      </.workbench_chassis>
      """)

    doc = LazyHTML.from_fragment(html)

    assert matches?(
             doc,
             "#instrument-workbench-chat.sf-chassis[data-workbench-surface=chat]"
           )

    assert matches?(
             doc,
             "#instrument-workbench-chat[aria-labelledby='instrument-workbench-chat-title']"
           )

    assert matches?(
             doc,
             "#return-to-instrument-deck-chat[data-phx-link='patch'][data-phx-link-state='replace'][data-return-instrument-id='instrument-card-chat']"
           )

    assert matches?(
             doc,
             "#instrument-workbench-chat-status[role='status'][aria-live='polite']"
           )

    assert Enum.count(
             LazyHTML.query(
               doc,
               "#instrument-workbench-chat [role='status'][aria-live='polite']"
             )
           ) == 1

    assert LazyHTML.text(doc) =~ "Ready"
    assert matches?(doc, "#primary-one")
    refute matches?(doc, "#primary-two")
    assert matches?(doc, "[data-workbench-local-modes] #mode-tabs")
    assert matches?(doc, "[data-workbench-primary-field] #primary-field")
    assert matches?(doc, "[data-workbench-signal-panel] #signal-panel")
    assert matches?(doc, "[data-workbench-command-dock] #command-dock")
    refute matches?(doc, "nav")
    refute matches?(doc, "form")

    ids =
      doc
      |> LazyHTML.query("#instrument-workbench-chat [id]")
      |> Enum.flat_map(&(LazyHTML.attribute(&1, "id") || []))

    assert ids == Enum.uniq(ids)

    for selector <- [
          "a[href] a[href]",
          "a[href] button",
          "button a[href]",
          "button button",
          "form form"
        ] do
      refute matches?(doc, "#instrument-workbench-chat #{selector}")
    end

    assert matches?(
             doc,
             "#instrument-workbench-chat > header + [data-workbench-local-modes] + #instrument-workbench-chat-fields + [data-workbench-command-dock]"
           )
  end

  test "omits optional slot wrappers when empty" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <.workbench_chassis
        id="instrument-workbench-files"
        surface="files"
        index="07"
        title="File Atlas"
        status="Idle"
        return_to="/"
        return_instrument_id="instrument-card-files"
      >
        <:primary_field>
          <div id="only-field">Field</div>
        </:primary_field>
      </.workbench_chassis>
      """)

    doc = LazyHTML.from_fragment(html)
    refute matches?(doc, "[data-workbench-local-modes]")
    refute matches?(doc, "[data-workbench-signal-panel]")
    refute matches?(doc, "[data-workbench-command-dock]")
    assert matches?(doc, "[data-workbench-primary-field] #only-field")
  end

  defp matches?(document, selector) do
    document |> LazyHTML.query(selector) |> LazyHTML.to_tree() != []
  end
end
