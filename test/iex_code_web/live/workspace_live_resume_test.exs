defmodule IexCodeWeb.WorkspaceLiveResumeTest do
  use IexCode.E2E.Case, async: false

  @surfaces ~w(kanban swarm research calendar changes chat files terminal)

  test "valid restore populates a deck-only resume shortcut for root and session contexts", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)

    for {url, prefix} <- [{"/", ""}, {"/sessions/#{session.id}", "/sessions/#{session.id}"}] do
      {:ok, view, _html} = live(conn, url)
      assigns = :sys.get_state(view.pid).socket.assigns

      assert has_element?(
               view,
               "#workspace-shell[phx-hook='InstrumentDeck'][data-active-view='deck'][data-project-id='#{assigns.project.id}'][data-session-id='#{assigns.session.id}']"
             )

      for surface <- @surfaces do
        render_hook(view, "restore_last_instrument", %{"surface" => surface})

        destination =
          if surface == "research" do
            "#{prefix}/research"
          else
            if prefix == "", do: "/?view=#{surface}", else: "#{prefix}?view=#{surface}"
          end

        assert has_element?(
                 view,
                 "a#resume-instrument[data-surface='#{surface}'][href='#{destination}']"
               )

        assert has_element?(view, "a#resume-instrument[data-phx-link='patch']")
        render_patch(view, destination)
        refute has_element?(view, "#resume-instrument")
        render_patch(view, url)
        assert has_element?(view, "#resume-instrument[data-surface='#{surface}']")
      end
    end
  end

  test "resume shortcut patches only after activation and invalid payloads are ignored", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    base = "/sessions/#{session.id}"
    {:ok, view, _html} = live(conn, base)

    for payload <- [
          %{},
          %{"surface" => nil},
          %{"surface" => "deck"},
          %{"surface" => "wat"},
          %{"surface" => :terminal},
          %{"surface" => ""}
        ] do
      render_hook(view, "restore_last_instrument", payload)
      refute has_element?(view, "#resume-instrument")
      refute_receive {_, {:patch, _, _}}, 0
    end

    render_hook(view, "restore_last_instrument", %{"surface" => "terminal"})
    assert has_element?(view, "#resume-instrument[data-surface='terminal']")
    refute_receive {_, {:patch, _, _}}, 0
    render_click(element(view, "#resume-instrument"))
    assert_patch(view, "#{base}?view=terminal")
    refute has_element?(view, "#resume-instrument")

    render_patch(view, base)
    assert has_element?(view, "#resume-instrument[data-surface='terminal']")
  end

  test "restore while on a workbench is retained but remains hidden until deck", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    base = "/sessions/#{session.id}"
    {:ok, view, _html} = live(conn, "#{base}?view=terminal")

    render_hook(view, "restore_last_instrument", %{"surface" => "research"})
    refute has_element?(view, "#resume-instrument")
    refute_receive {_, {:patch, _, _}}, 0
    render_patch(view, base)

    assert has_element?(
             view,
             "#resume-instrument[data-surface='research'][href='#{base}/research']"
           )
  end

  test "session and project context changes clear resume until the new context rehydrates", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    first = create_session_fixture(project)
    second = create_session_fixture(project)
    other_path = create_temp_workspace(%{})
    other_project = create_project_fixture(%{root_path: other_path})
    other_session = create_session_fixture(other_project)
    {:ok, view, _html} = live(conn, "/sessions/#{first.id}")

    render_hook(view, "restore_last_instrument", %{"surface" => "chat"})
    assert has_element?(view, "#resume-instrument[data-surface='chat']")

    render_patch(view, "/sessions/#{second.id}")
    refute has_element?(view, "#resume-instrument")
    render_hook(view, "restore_last_instrument", %{"surface" => "research"})

    assert has_element?(
             view,
             "#resume-instrument[data-surface='research'][href='/sessions/#{second.id}/research']"
           )

    render_patch(view, "/sessions/#{other_session.id}")
    refute has_element?(view, "#resume-instrument")
    render_hook(view, "restore_last_instrument", %{"surface" => "terminal"})

    assert has_element?(
             view,
             "#resume-instrument[data-surface='terminal'][href='/sessions/#{other_session.id}?view=terminal']"
           )
  end
end
