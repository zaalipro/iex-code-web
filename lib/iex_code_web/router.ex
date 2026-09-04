defmodule IexCodeWeb.Router do
  use IexCodeWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug IexCodeWeb.Plugs.LocalAccess
    plug :fetch_session
    plug IexCodeWeb.Plugs.Theme
    plug :fetch_live_flash
    plug :put_root_layout, html: {IexCodeWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :require_admin do
    plug IexCodeWeb.Plugs.RequireAdmin
  end

  pipeline :health do
    plug :accepts, ["json"]
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/health", IexCodeWeb do
    pipe_through :health

    get "/live", HealthController, :live
    get "/ready", HealthController, :ready
  end

  scope "/", IexCodeWeb do
    pipe_through :browser

    get "/login", AdminSessionController, :new
    post "/login", AdminSessionController, :create, log: false
    post "/logout", AdminSessionController, :delete
  end

  scope "/", IexCodeWeb do
    pipe_through [:browser, :require_admin]

    live_session :require_admin,
      on_mount: [{IexCodeWeb.AdminAuth, :require_admin}] do
      live "/", WorkspaceLive, :index
      live "/research", WorkspaceLive, :research
      live "/settings", SettingsLive, :index
      live "/settings/:tab", SettingsLive, :tab
      live "/sessions/:id", WorkspaceLive, :show
      live "/sessions/:id/research", WorkspaceLive, :research
      live "/sessions/:id/settings", SettingsLive, :session
      live "/sessions/:id/settings/:tab", SettingsLive, :session_tab

      # Workflows routes
      live "/workflows", WorkflowsLive, :index
      live "/workflows/new", WorkflowsLive, :new
      live "/create-workflow", WorkflowsLive, :new
      live "/workflows/:id", WorkflowsLive, :show
      live "/workflows/:id/runs/:run_id", WorkflowsLive, :run

      # Session-scoped Workflows routes
      live "/sessions/:id/workflows", WorkflowsLive, :session_index
      live "/sessions/:id/workflows/new", WorkflowsLive, :session_new
      live "/sessions/:id/workflows/:workflow_id", WorkflowsLive, :session_show
      live "/sessions/:id/workflows/:workflow_id/runs/:run_id", WorkflowsLive, :session_run

      scope "/sessions/:id/detached", Detached, as: :detached do
        live "/terminal", TerminalLive, :show
        live "/diff", DiffLive, :show
        live "/dag", DagLive, :show
      end
    end

    get "/research/:id/report", ResearchReportController, :show
    get "/research/:id/report/download", ResearchReportController, :download_html
    get "/research/:id/result/download", ResearchReportController, :download_markdown
  end

  # Other scopes may use custom stacks.
  # scope "/api", IexCodeWeb do
  #   pipe_through :api
  # end
end
