defmodule SuperXWeb.Router do
  use SuperXWeb, :router

  import SuperXWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {SuperXWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :authenticated_api do
    plug SuperXWeb.ApiAuth
    plug SuperXWeb.ApiRateLimit
  end

  # --- Public --------------------------------------------------------------

  scope "/", SuperXWeb do
    pipe_through :browser

    get "/", PageController, :home
    get "/sitemap.xml", SitemapController, :index
    get "/share/:token", AnalyticsShareController, :show
    get "/circle/:token", ContactListShareController, :show
    get "/team/invitations/:token", TeamInvitationController, :show
    post "/team/invitations/:token/accept", TeamInvitationController, :accept
    delete "/sign-out", AuthController, :delete
  end

  scope "/auth", SuperXWeb do
    pipe_through :browser

    get "/x", AuthController, :request
    get "/x/callback", AuthController, :callback
  end

  # --- Signed in, but may not have connected an account yet ----------------

  scope "/", SuperXWeb do
    pipe_through [:browser, :require_authenticated_user]

    get "/uploads/:id", UploadController, :show
    get "/contacts/export", ContactExportController, :show

    live_session :authenticated,
      on_mount: [{SuperXWeb.UserAuth, :ensure_authenticated}, SuperXWeb.ShellHook],
      layout: {SuperXWeb.Layouts, :app} do
      live "/connect", ConnectLive, :index
      live "/accounts", AccountsLive, :index
      live "/api", ApiDocsLive, :index
    end
  end

  # --- Signed in with at least one connected X account ---------------------

  scope "/", SuperXWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :app,
      on_mount: [{SuperXWeb.UserAuth, :ensure_onboarded}, SuperXWeb.ShellHook],
      layout: {SuperXWeb.Layouts, :app} do
      live "/welcome", WelcomeLive, :index
      live "/home", HomeLive, :index
      live "/ask", AskLive, :index
      live "/ask/:id", AskLive, :show

      live "/queue", QueueLive, :index
      live "/queue/:id", QueueLive, :edit

      live "/articles", ArticlesLive, :index
      live "/articles/new", ArticlesLive, :new
      live "/articles/:id/edit", ArticlesLive, :edit

      live "/ready-to-post", ReadyToPostLive, :index
      live "/workers", WorkersLive, :index
      live "/engage", EngageLive, :index
      live "/inspiration", InspirationLive, :index
      live "/signals", SignalsLive, :index
      live "/contacts", ContactsLive, :index
      live "/dms", DMsLive, :index
      live "/analytics", AnalyticsLive, :index

      live "/voice", VoiceLive, :index
      live "/settings", SettingsLive, :index
    end
  end

  # --- Webhooks ------------------------------------------------------------

  scope "/webhooks", SuperXWeb do
    pipe_through :api
  end

  # --- Programmatic API ---------------------------------------------------

  scope "/api", SuperXWeb do
    pipe_through [:api, :authenticated_api]

    get "/queue", ApiController, :queue
    get "/shelf", ApiController, :shelf
    get "/analytics", ApiController, :analytics
    post "/posts", ApiController, :create_post
    post "/posts/:id/schedule", ApiController, :schedule_post
    delete "/posts/:id", ApiController, :delete_post
  end

  # MCP clients advertise JSON and SSE together on POST, and SSE alone on
  # GET. The ordinary API content negotiation would turn the required GET
  # probe into a 406 before the controller can give its meaningful 405.
  scope "/", SuperXWeb do
    pipe_through :authenticated_api

    get "/mcp", MCPController, :stream
    post "/mcp", MCPController, :handle
    delete "/mcp", MCPController, :close
  end

  if Application.compile_env(:superx, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev", SuperXWeb do
      pipe_through :browser

      get "/sign-in/:id", DevAuthController, :create
    end

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: SuperXWeb.Telemetry, ecto_repos: [SuperX.Repo]
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
