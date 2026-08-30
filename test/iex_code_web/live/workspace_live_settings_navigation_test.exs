defmodule IexCodeWeb.WorkspaceLiveSettingsNavigationTest do
  use IexCode.E2E.Case, async: false

  @moduletag mock_llm: true

  test "workspace settings shims navigate to anchored SettingsLive", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    render_click(view, "toggle_settings_modal")
    assert_redirect(view, "/sessions/#{session.id}/settings#execution")

    {:ok, settings_view, _html} = live(conn, ~p"/sessions/#{session.id}/settings#execution")
    assert has_element?(settings_view, "#settings-form")
    assert has_element?(settings_view, "#execution")

    {:ok, research_view, _html} = live(conn, ~p"/sessions/#{session.id}/research")

    assert has_element?(
             research_view,
             "#research-open-settings[href='/sessions/#{session.id}/settings#providers']"
           )
  end

  test "root settings links use root context", %{conn: conn, workspace_path: path} do
    project = create_project_fixture(%{root_path: path})
    _session = create_session_fixture(project)
    {:ok, view, _html} = live(conn, ~p"/")

    render_click(view, "toggle_command_palette", %{"category" => "settings_account"})

    assert has_element?(
             view,
             "[data-palette-item-id='settings-models'][data-palette-href='/settings#models']"
           )

    assert has_element?(
             view,
             "[data-palette-item-id='settings-runtime'][data-palette-href='/settings#runtime']"
           )

    for {id, anchor} <- [
          {"settings-models", "models"},
          {"settings-execution", "execution"},
          {"settings-research", "research"},
          {"settings-runtime", "runtime"}
        ] do
      assert has_element?(
               view,
               "[data-palette-item-id='#{id}'][data-palette-href='/settings##{anchor}']"
             )
    end

    assigns = :sys.get_state(view.pid).socket.assigns
    refute Map.has_key?(assigns, :show_settings_modal)
    refute Map.has_key?(assigns, :settings_form)
  end

  test "session settings palette rows execute anchored navigation", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
    render_click(view, "toggle_command_palette", %{"category" => "settings_account"})

    view |> element("[data-palette-item-id='settings-research']") |> render_click()
    assert_redirect(view, "/sessions/#{session.id}/settings#research")
  end

  test "runtime trigger navigates exactly and the workbench action is truthful", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    view |> element("#runtime-switchboard-trigger") |> render_click()
    assert_redirect(view, "/sessions/#{session.id}/settings#runtime")

    {:ok, workbench, _html} = live(conn, ~p"/sessions/#{session.id}?view=kanban")
    assert has_element?(workbench, "#return-to-instrument-deck-action")
    refute has_element?(workbench, "#new-mission-button")
  end
end
