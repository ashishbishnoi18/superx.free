defmodule SuperXWeb.PageController do
  use SuperXWeb, :controller

  plug :redirect_if_authenticated when action in [:home]

  @features [
    %{
      icon: "hero-microphone",
      title: "Writes in your voice",
      body:
        "It reads your own posts to learn how you actually sound, then drafts in that voice — not in assistant-speak."
    },
    %{
      icon: "hero-light-bulb",
      title: "Learns from what works",
      body:
        "Every draft starts from a post that genuinely outperformed, so you're borrowing structure that already earned attention."
    },
    %{
      icon: "hero-calendar-days",
      title: "Keeps the queue full",
      body:
        "Set the times you want to post. Approved drafts fill the next open slot and go out on their own."
    }
  ]

  def home(conn, _params) do
    conn
    |> assign(:x_configured, SuperX.X.configured?())
    |> assign(:features, @features)
    |> assign(:page_title, "Grow on X without living on X")
    |> render(:home, layout: false)
  end

  defp redirect_if_authenticated(conn, _opts),
    do: SuperXWeb.UserAuth.redirect_if_authenticated(conn, [])
end
