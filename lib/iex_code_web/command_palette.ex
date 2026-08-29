defmodule IexCodeWeb.CommandPalette do
  @moduledoc "Server-owned search index for the Signal Foundry switchboard."

  @type action_item :: %{
          required(:id) => String.t(),
          required(:category) => :action,
          required(:title) => String.t(),
          required(:event) => String.t(),
          required(:params) => map()
        }
  @type view_item :: %{
          required(:id) => String.t(),
          required(:category) => :view,
          required(:title) => String.t(),
          required(:tab) => String.t()
        }
  @type navigation_item :: %{
          required(:id) => String.t(),
          required(:category) => :navigation,
          required(:title) => String.t(),
          required(:href) => String.t()
        }
  @type session_item :: %{
          required(:id) => String.t(),
          required(:category) => :session,
          required(:title) => String.t(),
          required(:session_id) => String.t()
        }
  @type project_item :: %{
          required(:id) => String.t(),
          required(:category) => :project,
          required(:title) => String.t(),
          required(:project_id) => String.t()
        }
  @type account_item :: %{
          required(:id) => String.t(),
          required(:category) => :account,
          required(:title) => String.t(),
          required(:event) => String.t(),
          required(:params) => map()
        }
  @type confirmation_item :: %{
          required(:id) => String.t(),
          required(:category) => :confirmation,
          required(:title) => String.t(),
          required(:event) => String.t(),
          required(:params) => map(),
          required(:confirmation) => String.t()
        }
  @type palette_item ::
          action_item()
          | view_item()
          | navigation_item()
          | session_item()
          | project_item()
          | account_item()
          | confirmation_item()

  @max_dynamic_results 10
  @max_label_length 160
  @actions [
    %{
      id: "start_goal",
      category: :action,
      title: "Start New Goal",
      subtitle: "Launch an autonomous mission",
      icon: "hero-flag",
      shortcut: "Cmd+G",
      event: "open_goal_modal",
      params: %{}
    },
    %{
      id: "new_task",
      category: :action,
      title: "New Kanban Task",
      subtitle: "Create and dispatch a task",
      icon: "hero-plus",
      shortcut: "Cmd+N",
      event: "toggle_new_task_modal",
      params: %{}
    },
    %{
      id: "new-session",
      category: :action,
      title: "New Session",
      subtitle: "Start a clean session",
      icon: "hero-document-plus",
      shortcut: "",
      event: "new_session",
      params: %{}
    },
    %{
      id: "toggle_swarm",
      category: :action,
      title: "Toggle Swarm Mode",
      subtitle: "Change interactive session mode",
      icon: "hero-cpu-chip",
      shortcut: "",
      event: "toggle_swarm",
      params: %{}
    },
    %{
      id: "git_fetch",
      category: :action,
      title: "Git Fetch and Status",
      subtitle: "Refresh repository state",
      icon: "hero-arrow-down-tray",
      shortcut: "",
      event: "git_fetch",
      params: %{}
    }
  ]
  @views [
    %{
      id: "view_swarm",
      category: :view,
      title: "Active Mission",
      subtitle: "Mission telemetry",
      icon: "hero-sparkles",
      tab: "swarm"
    },
    %{
      id: "view_kanban",
      category: :view,
      title: "Mission Board",
      subtitle: "Tasks and priorities",
      icon: "hero-squares-2x2",
      tab: "kanban"
    },
    %{
      id: "view_research",
      category: :view,
      title: "Research Radar",
      subtitle: "Cited findings",
      icon: "hero-globe-alt",
      tab: "research"
    },
    %{
      id: "view_calendar",
      category: :view,
      title: "Schedule Chronometer",
      subtitle: "Time and schedules",
      icon: "hero-calendar",
      tab: "calendar"
    },
    %{
      id: "view_changes",
      category: :view,
      title: "Change Ledger",
      subtitle: "Diffs and commits",
      icon: "hero-code-bracket",
      tab: "changes"
    },
    %{
      id: "view_chat",
      category: :view,
      title: "Conversation Loop",
      subtitle: "Prompts and reasoning",
      icon: "hero-chat-bubble-left-right",
      tab: "chat"
    },
    %{
      id: "view_files",
      category: :view,
      title: "File Atlas",
      subtitle: "Project files",
      icon: "hero-folder",
      tab: "files"
    },
    %{
      id: "view_terminal",
      category: :view,
      title: "Terminal Scope",
      subtitle: "Command execution",
      icon: "hero-command-line",
      tab: "terminal"
    }
  ]

  @spec search(String.t() | nil, [%IexCode.Sessions.Session{}], String.t()) :: [palette_item()]
  def search(query, sessions, category_filter \\ "all") do
    query = normalize_query(query)
    category = normalize_category(category_filter)

    if is_nil(category) do
      []
    else
      search_items(query, sessions, category)
    end
  end

  defp search_items(query, sessions, category) do
    actions = if category in ["all", "actions"], do: filter_items(@actions, query), else: []
    views = if category in ["all", "views"], do: filter_items(@views, query), else: []

    session_items =
      if category in ["all", "sessions"] do
        sessions
        |> Enum.uniq_by(&Map.get(&1, :id))
        |> Enum.map(&session_item/1)
        |> Enum.filter(&matches?(&1.title, query))
        |> Enum.take(@max_dynamic_results)
      else
        []
      end

    views ++ actions ++ session_items
  end

  @spec project_items(String.t() | nil, Enumerable.t()) :: [project_item()]
  def project_items(query, projects) do
    query = normalize_query(query)

    projects
    |> Enum.uniq_by(&Map.get(&1, :id))
    |> Enum.map(fn project ->
      id = to_string(Map.get(project, :id, ""))
      title = bounded_label(Map.get(project, :name))

      %{
        id: "project-#{id}",
        category: :project,
        title: if(title == "", do: "Project", else: title),
        subtitle: "Switch workspace",
        icon: "hero-cube",
        project_id: id
      }
    end)
    |> Enum.filter(&matches?(&1.title, query))
    |> Enum.take(@max_dynamic_results)
  end

  def actions, do: @actions
  def views, do: @views

  defp session_item(session) do
    id = to_string(Map.get(session, :id, ""))
    title = bounded_label(Map.get(session, :title))

    title = if title == "", do: "Session #{String.slice(id, 0, 8)}", else: title

    %{
      id: "session_#{id}",
      category: :session,
      title: title,
      subtitle: "Open session",
      icon: "hero-document-text",
      session_id: id
    }
  end

  defp filter_items(items, ""), do: items

  defp filter_items(items, query),
    do:
      Enum.filter(
        items,
        &(matches?(&1.title, query) or matches?(Map.get(&1, :subtitle, ""), query))
      )

  defp normalize_query(query) when is_binary(query),
    do: query |> String.trim() |> String.downcase()

  defp normalize_query(_query), do: ""

  defp normalize_category(category)
       when category in ["all", "views", "projects", "sessions", "actions", "settings_account"],
       do: category

  defp normalize_category(_category), do: nil
  defp matches?(_value, ""), do: true

  defp matches?(value, query),
    do: value |> to_string() |> String.downcase() |> String.contains?(query)

  defp bounded_label(value) when is_binary(value),
    do: value |> String.slice(0, @max_label_length) |> String.trim()

  defp bounded_label(_value), do: ""
end
