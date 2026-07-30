defmodule SuperXWeb.ConnectLive do
  @moduledoc """
  Shown when a signed-in user has no connected X account yet — the only
  state in which the rest of the app has nothing to render.
  """

  use SuperXWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    # Someone who already connected an account shouldn't be stuck here.
    if socket.assigns.current_x_account do
      {:ok, push_navigate(socket, to: ~p"/home")}
    else
      {:ok, assign(socket, page_title: "Connect your account")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-[46ch] py-16">
      <h1 class="text-[1.75rem] font-semibold leading-[1.15] tracking-[-0.03em]">
        Connect your 𝕏 account
      </h1>
      <p class="mt-3 leading-[1.6] text-muted-foreground">
        SuperX reads your own posts to learn how you write, and publishes the ones
        you approve. It never posts anything you haven't seen.
      </p>

      <.link href={~p"/auth/x"} class="act-key mt-7 inline-block">
        Connect with 𝕏 →
      </.link>

      <ul class="mt-10 flex flex-col">
        <li
          :for={
            {what, why} <- [
              {"Read your posts", "so drafts sound like you, not like an assistant"},
              {"Publish on your behalf", "only what you've approved, at the times you set"},
              {"Read your profile metrics", "for the analytics page"}
            ]
          }
          class="grid grid-cols-1 gap-4 border-t border-border py-3.5 last:border-b sm:grid-cols-[12rem_minmax(0,1fr)]"
        >
          <span class="font-medium">{what}</span>
          <span class="text-muted-foreground">{why}</span>
        </li>
      </ul>
    </div>
    """
  end
end
