defmodule XebaWeb.Router do
  use XebaWeb, :router

  import XebaWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {XebaWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :media do
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_secure_browser_headers
    plug :fetch_current_scope
  end

  scope "/", XebaWeb do
    pipe_through [:media, :require_authenticated_user]
    get "/chats/:chat_id/stickers/:id/media", StickerMediaController, :show
    get "/chats/:chat_id/exchanges/:id/media", StickerMediaController, :exchange
  end

  scope "/health", XebaWeb do
    pipe_through :api

    get "/live", HealthController, :live
    get "/ready", HealthController, :ready
  end

  # Other scopes may use custom stacks.
  # scope "/api", XebaWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard in development
  if Application.compile_env(:xeba, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: XebaWeb.Telemetry
    end
  end

  scope "/", XebaWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :require_authenticated_user,
      on_mount: [{XebaWeb.UserAuth, :require_authenticated}] do
      live "/", ExchangeLive, :index
      live "/chats/:chat_id", ExchangeLive, :show
      live "/chats/:chat_id/transcript", TranscriptLive, :show
      live "/chats/:chat_id/stickers", StickerBankLive, :show
      live "/autonomous", AutonomousLive, :index
    end
  end

  scope "/", XebaWeb do
    pipe_through [:browser]

    live_session :current_user,
      on_mount: [{XebaWeb.UserAuth, :mount_current_scope}] do
      live "/log-in", LoginLive, :new
    end

    post "/log-in", UserSessionController, :create
    delete "/log-out", UserSessionController, :delete
  end
end
