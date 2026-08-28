defmodule IexCodeWeb.WorkspaceLiveSignalFoundryNavigationTest do
  use IexCode.E2E.Case, async: false

  alias IexCode.Tools.TerminalServer

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
    assert_replace_patch(root_research, "/research")

    render_patch(session_research, "/sessions/#{session.id}/research?view=terminal")
    assert_replace_patch(session_research, "/sessions/#{session.id}/research")
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

  test "id query keys never become session route context", %{conn: conn, workspace_path: path} do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    {:ok, root_view, _html} = live(conn, ~p"/")
    root_session_id = :sys.get_state(root_view.pid).socket.assigns.session.id

    render_patch(root_view, "/?id=#{session.id}")
    assert_replace_patch(root_view, "/")
    root_assigns = :sys.get_state(root_view.pid).socket.assigns
    assert root_assigns.workspace_route == :root
    assert root_assigns.session.id == root_session_id

    {:ok, research_view, _html} = live(conn, ~p"/research")
    render_patch(research_view, "/research?id=#{session.id}")
    assert_replace_patch(research_view, "/research")
    assert :sys.get_state(research_view.pid).socket.assigns.workspace_route == :root

    {:ok, session_view, _html} = live(conn, ~p"/sessions/#{session.id}")
    render_patch(session_view, "/sessions/#{session.id}?id=query-value")
    assert_replace_patch(session_view, "/sessions/#{session.id}")

    session_assigns = :sys.get_state(session_view.pid).socket.assigns
    assert session_assigns.workspace_route == {:session, session.id}
    assert session_assigns.session.id == session.id
  end

  test "direct Files and Changes URLs run their activation lifecycles", %{
    conn: conn,
    workspace_path: path
  } do
    workspace_write_file(path, "lib/url_activation.ex", "defmodule UrlActivation, do: :ok\n")
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)

    {:ok, files_view, _html} = live(conn, ~p"/sessions/#{session.id}?view=files")
    files_assigns = :sys.get_state(files_view.pid).socket.assigns
    assert files_assigns.files_loaded?
    assert "lib/url_activation.ex" in files_assigns.project_files

    {:ok, changes_view, _html} = live(conn, ~p"/sessions/#{session.id}?view=changes")
    changes_assigns = :sys.get_state(changes_view.pid).socket.assigns
    assert changes_assigns.git_status || is_binary(changes_assigns.git_error)
  end

  test "URL terminal activation attaches and transitioning away detaches the viewer", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    render_patch(view, "/sessions/#{session.id}?view=terminal")
    assert :sys.get_state(view.pid).socket.assigns.terminal_running?
    assert {:ok, %{viewer_count: 1}} = TerminalServer.get_state(session.id)

    render_patch(view, "/sessions/#{session.id}")
    assert {:ok, %{viewer_count: 0}} = TerminalServer.get_state(session.id)
  end

  test "cross-session terminal to non-terminal navigation releases the old viewer", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    first_session = create_session_fixture(project)
    second_session = create_session_fixture(project)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{first_session.id}")

    render_patch(view, "/sessions/#{first_session.id}?view=terminal")

    assert {:ok, %{viewer_count: 1}} = TerminalServer.get_state(first_session.id)

    render_patch(view, "/sessions/#{second_session.id}?view=files")
    assert :sys.get_state(view.pid).socket.assigns.session.id == second_session.id
    assert {:ok, %{viewer_count: 0}} = TerminalServer.get_state(first_session.id)
    assert :sys.get_state(view.pid).socket.assigns.files_loaded?
  end

  test "switch_tab payloads patch exact workspace URLs", %{conn: conn, workspace_path: path} do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    render_click(view, "switch_tab", %{"tab" => "terminal"})
    assert_push_patch(view, "/sessions/#{session.id}?view=terminal")

    render_click(view, "switch_tab", %{"sidebar_tab" => "calendar"})
    assert_push_patch(view, "/sessions/#{session.id}?view=calendar")

    render_click(view, "switch_tab", %{"tab" => "research"})
    assert_push_patch(view, "/sessions/#{session.id}/research")

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
