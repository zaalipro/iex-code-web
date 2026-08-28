defmodule IexCodeWeb.WorkspaceLiveSignalFoundryNavigationTest do
  use IexCode.E2E.Case, async: false

  test "canonical workspace defaults mount deck with compatibility tab", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)

    {:ok, view, _html} = live(conn, ~p"/")
    assigns = :sys.get_state(view.pid).socket.assigns

    assert assigns.workspace_views ==
             ~w(deck kanban swarm research calendar changes chat files terminal)

    assert assigns.active_view == "deck"
    assert assigns.active_tab == "kanban"
    assert has_element?(view, "#sidebar-tab-research[href='/research']")
    assert has_element?(view, "#tab-btn-research[href='/research']")

    {:ok, session_view, _html} = live(conn, ~p"/sessions/#{session.id}")
    session_assigns = :sys.get_state(session_view.pid).socket.assigns
    assert session_assigns.active_view == "deck"
    assert session_assigns.active_tab == "kanban"

    assert has_element?(
             session_view,
             "#sidebar-tab-research[href='/sessions/#{session.id}/research']"
           )
  end

  for view_name <- ~w(kanban swarm calendar changes chat files terminal) do
    test "session query #{view_name} is canonical workspace view", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}?view=#{unquote(view_name)}")

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.active_view == unquote(view_name)
      assert assigns.active_tab == unquote(view_name)
    end
  end

  test "research routes and query conflicts canonicalize", %{conn: conn, workspace_path: path} do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)

    {:ok, root_research, _html} = live(conn, ~p"/research")
    assigns = :sys.get_state(root_research.pid).socket.assigns
    assert assigns.active_view == "research"
    assert assigns.active_tab == "research"

    {:ok, session_research, _html} = live(conn, ~p"/sessions/#{session.id}/research")
    session_assigns = :sys.get_state(session_research.pid).socket.assigns
    assert session_assigns.active_view == "research"
    assert session_assigns.active_tab == "research"

    render_patch(root_research, "/research?view=terminal")
    assert_patch(root_research, "/research")

    render_patch(session_research, "/sessions/#{session.id}/research?view=terminal")
    assert_patch(session_research, "/sessions/#{session.id}/research")
  end

  test "research query values and malformed values replace to canonical paths", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    {:ok, root_view, _html} = live(conn, ~p"/")

    render_patch(root_view, "/?view=research")
    assert_replace_patch(root_view, "/research")

    render_patch(root_view, "/?view=wat")
    assert_replace_patch(root_view, "/")

    render_patch(root_view, "/?view=")
    assert_replace_patch(root_view, "/")

    render_patch(root_view, "/?view=deck")
    assert_replace_patch(root_view, "/")

    render_patch(root_view, "/?view=terminal&extra=1")
    assert_replace_patch(root_view, "/")

    {:ok, session_view, _html} = live(conn, ~p"/sessions/#{session.id}")
    render_patch(session_view, "/sessions/#{session.id}?view=research")
    assert_replace_patch(session_view, "/sessions/#{session.id}/research")

    render_patch(session_view, "/sessions/#{session.id}?view=wat")
    assert_replace_patch(session_view, "/sessions/#{session.id}")
  end

  test "direct malformed workspace URLs redirect without adding history", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    research_path = "/sessions/#{session.id}/research"

    assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, "/?view=wat")

    assert {:error, {:live_redirect, %{to: ^research_path}}} =
             live(conn, "/sessions/#{session.id}?view=research")
  end

  test "switch_tab payloads patch exact workspace URLs", %{conn: conn, workspace_path: path} do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    render_click(view, "switch_tab", %{"tab" => "terminal"})
    assert_push_patch(view, "/sessions/#{session.id}?view=terminal")

    render_click(view, "switch_tab", %{"sidebar_tab" => "calendar"})
    assert_patch(view, "/sessions/#{session.id}?view=calendar")

    render_click(view, "switch_tab", %{"tab" => "research"})
    assert_patch(view, "/sessions/#{session.id}/research")

    assigns = :sys.get_state(view.pid).socket.assigns
    assert assigns.active_view == "research"
    assert assigns.active_tab == "research"

    before = assigns
    render_click(view, "switch_tab", %{"tab" => "wat"})
    after_assigns = :sys.get_state(view.pid).socket.assigns
    assert after_assigns.active_view == before.active_view
    assert after_assigns.active_tab == before.active_tab

    render_click(view, "switch_tab", %{"sidebar_tab" => "wat"})
    refute_receive {_, {:patch, _, _}}, 50
  end

  test "root tab events stay on root-scoped workspace routes", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    _session = create_session_fixture(project)
    {:ok, view, _html} = live(conn, ~p"/")

    render_click(view, "switch_tab", %{"tab" => "terminal"})
    assert_push_patch(view, "/?view=terminal")

    render_click(view, "switch_tab", %{"sidebar_tab" => "research"})
    assert_push_patch(view, "/research")
  end

  test "explicit palette and composer view navigation stays URL-backed", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    render_click(view, "toggle_command_palette")
    render_click(view, "command_palette_set_category", %{"category" => "views"})
    render_change(view, "command_palette_search", %{"query" => "Terminal Shell"})
    render_click(view, "command_palette_execute_selected")
    assert_push_patch(view, "/sessions/#{session.id}?view=terminal")

    render_submit(view, "submit_prompt", %{"prompt" => "/kanban"})
    assert_push_patch(view, "/sessions/#{session.id}?view=kanban")

    render_submit(view, "submit_prompt", %{"prompt" => "/research"})
    assert_push_patch(view, "/sessions/#{session.id}/research")
    assert :sys.get_state(view.pid).socket.assigns.active_view == "research"
  end

  defp assert_replace_patch(%{proxy: {ref, topic, _proxy_pid}}, to) do
    assert_receive {^ref, {:patch, ^topic, %{to: ^to, kind: :replace}}}
  end

  defp assert_push_patch(%{proxy: {ref, topic, _proxy_pid}}, to) do
    assert_receive {^ref, {:patch, ^topic, %{to: ^to, kind: :push}}}
  end
end
