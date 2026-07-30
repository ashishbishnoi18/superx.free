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
    <div class="mx-auto max-w-lg py-12 text-center">
      <div class="mx-auto flex size-14 items-center justify-center rounded-2xl bg-ember-50">
        <.icon name="hero-at-symbol" class="size-7 text-ember-600" />
      </div>

      <h1 class="mt-6 text-2xl font-bold tracking-tight">Connect your 𝕏 account</h1>
      <p class="mt-3 text-sm leading-relaxed" style="color: var(--text-secondary)">
        SuperX needs access to post on your behalf and to read your own posts,
        which is how it learns the way you write. It never posts anything you
        haven't approved.
      </p>

      <.link href={~p"/auth/x"} class="btn btn-primary btn-lg mt-8">
        Connect with <span class="font-bold">𝕏</span>
      </.link>

      <ul class="mt-10 space-y-3 text-left text-sm" style="color: var(--text-secondary)">
        <li :for={
          item <- [
            "Read your posts to learn your voice",
            "Publish the posts you schedule",
            "Read your profile metrics for analytics"
          ]
        } class="flex items-start gap-2.5">
          <.icon name="hero-check-circle" class="mt-0.5 size-4 shrink-0 text-ember-600" />
          <span>{item}</span>
        </li>
      </ul>
    </div>
    """
  end
end
