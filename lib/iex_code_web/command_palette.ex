defmodule IexCodeWeb.CommandPalette do
  @moduledoc """
  Search indexing and fuzzy ranking engine for the Command Palette.
  Provides instant keyboard navigation and jumping across actions, views,
  project files, and workspace sessions.
  """

  @actions [
    %{
      id: "run_all_tests",
      category: :action,
      title: "Run All Tests",
      subtitle: "Execute full ExUnit suite with progress",
      icon: "hero-beaker",
      shortcut: "Cmd+T",
      event: "run_tests",
      params: %{"mode" => "all"}
    },
    %{
      id: "run_failed_tests",
      category: :action,
      title: "Run Failed Tests",
      subtitle: "Re-run only previously failed tests",
      icon: "hero-arrow-path",
      shortcut: "Cmd+Shift+T",
      event: "run_tests",
      params: %{"mode" => "failed"}
    },
    %{
      id: "run_stale_tests",
      category: :action,
      title: "Run Stale Tests",
      subtitle: "Run tests affected by modified files",
      icon: "hero-bolt",
      shortcut: "",
      event: "run_tests",
      params: %{"mode" => "stale"}
    },
    %{
      id: "start_goal",
      category: :action,
      title: "Start New Goal",
      subtitle: "Launch autonomous multi-agent swarm",
      icon: "hero-flag",
      shortcut: "Cmd+G",
      event: "open_goal_modal",
      params: %{}
    },
    %{
      id: "trigger_autofix",
      category: :action,
      title: "Trigger AutoFix Studio",
      subtitle: "Auto-repair test failures & compiler errors",
      icon: "hero-sparkles",
      shortcut: "Cmd+Shift+F",
      event: "open_autofix_studio",
      params: %{}
    },
    %{
      id: "ast_search",
      category: :action,
      title: "AST Symbol Search",
      subtitle: "Query functions, macros, and modules",
      icon: "hero-magnifying-glass",
      shortcut: "Cmd+Shift+O",
      event: "open_ast_explorer",
      params: %{}
    },
    %{
      id: "new_task",
      category: :action,
      title: "New Kanban Task",
      subtitle: "Create task and dispatch to worker",
      icon: "hero-plus",
      shortcut: "Cmd+N",
      event: "toggle_new_task_modal",
      params: %{}
    },
    %{
      id: "new_session",
      category: :action,
      title: "New Session",
      subtitle: "Start clean session in current workspace",
      icon: "hero-document-plus",
      shortcut: "",
      event: "new_session",
      params: %{}
    },
    %{
      id: "toggle_swarm",
      category: :action,
      title: "Toggle Swarm Mode",
      subtitle: "Switch between Single Agent & 4-Agent Swarm",
      icon: "hero-cpu-chip",
      shortcut: "",
      event: "toggle_swarm",
      params: %{}
    },
    %{
      id: "open_settings",
      category: :action,
      title: "Settings & API Keys",
      subtitle: "Open model, execution, swarm, research, and runtime settings",
      icon: "hero-cog-6-tooth",
      shortcut: "Cmd+,",
      event: "open_settings_page",
      params: %{}
    },
    %{
      id: "git_fetch",
      category: :action,
      title: "Git Fetch & Status",
      subtitle: "Refresh repository status and diffs",
      icon: "hero-arrow-down-tray",
      shortcut: "",
      event: "refresh_git_status",
      params: %{}
    }
  ]

  @views [
    %{
      id: "view_kanban",
      category: :view,
      title: "Dashboard / Kanban",
      subtitle: "Task board, workflow columns & priorities",
      icon: "hero-squares-2x2",
      tab: "kanban"
    },
    %{
      id: "view_swarm",
      category: :view,
      title: "Coach & Swarm Telemetry",
      subtitle: "Live agent cards, iteration progress & reasoning",
      icon: "hero-sparkles",
      tab: "swarm"
    },
    %{
      id: "view_calendar",
      category: :view,
      title: "Scheduled Tasks & Calendar",
      subtitle: "Time slots, presence availability & cron jobs",
      icon: "hero-calendar",
      tab: "calendar"
    },
    %{
      id: "view_changes",
      category: :view,
      title: "Progress & Diffs Hub",
      subtitle: "Git staging, multi-file diffs & commit generation",
      icon: "hero-code-bracket",
      tab: "changes"
    },
    %{
      id: "view_tests",
      category: :view,
      title: "Visual Test Runner & AutoFix",
      subtitle: "ExUnit runner, failure cards & 1-click patches",
      icon: "hero-beaker",
      tab: "tests"
    },
    %{
      id: "view_ast",
      category: :view,
      title: "AST Query Explorer",
      subtitle: "Code structure, function definitions & callers",
      icon: "hero-cube-transparent",
      tab: "ast"
    },
    %{
      id: "view_chat",
      category: :view,
      title: "Chat Assistant",
      subtitle: "Interactive reasoning & prompt dialog",
      icon: "hero-chat-bubble-left-right",
      tab: "chat"
    },
    %{
      id: "view_files",
      category: :view,
      title: "Resources & Files",
      subtitle: "Project tree & interactive inline code editor",
      icon: "hero-folder",
      tab: "files"
    },
    %{
      id: "view_terminal",
      category: :view,
      title: "Terminal Shell",
      subtitle: "Integrated command executor & log streamer",
      icon: "hero-command-line",
      tab: "terminal"
    }
  ]

  @doc """
  Performs fuzzy search across actions, views, project files, and sessions.
  Filters by category if category is not "all".
  """
  def search(query, files, sessions, category_filter \\ "all") do
    q = String.trim(String.downcase(query || ""))

    actions =
      if category_filter in ["all", "actions"], do: filter_items(@actions, q), else: []

    views =
      if category_filter in ["all", "views"], do: filter_items(@views, q), else: []

    file_items =
      if category_filter in ["all", "files"] do
        files
        |> Enum.filter(&matches_query?(&1, q))
        |> Enum.take(25)
        |> Enum.map(fn path ->
          %{
            id: "file_#{path}",
            category: :file,
            title: Path.basename(path),
            subtitle: path,
            icon: file_icon(path),
            path: path
          }
        end)
      else
        []
      end

    session_items =
      if category_filter in ["all", "sessions"] do
        sessions
        |> Enum.filter(fn s ->
          title = Map.get(s, :title) || ""
          id = to_string(Map.get(s, :id, ""))
          matches_query?(title, q) or matches_query?(id, q)
        end)
        |> Enum.take(10)
        |> Enum.map(fn s ->
          title = Map.get(s, :title)
          id = to_string(Map.get(s, :id, ""))
          updated_at = Map.get(s, :updated_at)

          subtitle =
            case updated_at do
              %DateTime{} = dt -> "Updated #{Calendar.strftime(dt, "%b %d, %H:%M")}"
              %NaiveDateTime{} = ndt -> "Updated #{Calendar.strftime(ndt, "%b %d, %H:%M")}"
              str when is_binary(str) -> "Updated #{str}"
              _ -> "Session #{String.slice(id, 0..7)}"
            end

          %{
            id: "session_#{id}",
            category: :session,
            title: if(title && title != "", do: title, else: "Session #{String.slice(id, 0..7)}"),
            subtitle: subtitle,
            icon: "hero-document-text",
            session_id: id
          }
        end)
      else
        []
      end

    actions ++ views ++ file_items ++ session_items
  end

  def actions, do: @actions
  def views, do: @views

  defp filter_items(items, ""), do: items

  defp filter_items(items, q) do
    Enum.filter(items, fn item ->
      matches_query?(item.title, q) or matches_query?(item.subtitle, q) or
        matches_query?(Map.get(item, :tab, ""), q) or
        matches_query?(Map.get(item, :event, ""), q)
    end)
  end

  defp matches_query?(_target, ""), do: true

  defp matches_query?(target, q) do
    target_str = String.downcase(to_string(target))
    String.contains?(target_str, q)
  end

  defp file_icon(path) do
    case Path.extname(path) do
      ".ex" -> "hero-code-bracket"
      ".exs" -> "hero-code-bracket-square"
      ".heex" -> "hero-cube"
      ".js" -> "hero-cpu-chip"
      ".css" -> "hero-paint-brush"
      ".md" -> "hero-document-text"
      ".json" -> "hero-document-chart-bar"
      _ -> "hero-document"
    end
  end
end
