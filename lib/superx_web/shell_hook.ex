defmodule SuperXWeb.ShellHook do
  @moduledoc """
  Assigns what the app shell needs on every LiveView: quota meter and the
  active nav item.

  `:active` is derived from the live action's module rather than set by
  hand in each view, so adding a page can't silently leave the sidebar
  unhighlighted.
  """

  import Phoenix.Component
  import Phoenix.LiveView

  alias SuperX.Billing

  @nav_by_module %{
    SuperXWeb.HomeLive => :home,
    SuperXWeb.AskLive => :ask,
    SuperXWeb.QueueLive => :queue,
    SuperXWeb.ArticlesLive => :articles,
    SuperXWeb.AnalyticsLive => :analytics,
    SuperXWeb.ReadyToPostLive => :ready_to_post,
    SuperXWeb.EngageLive => :engage,
    SuperXWeb.InspirationLive => :inspiration,
    SuperXWeb.SignalsLive => :signals,
    SuperXWeb.ContactsLive => :contacts,
    SuperXWeb.VoiceLive => :voice,
    SuperXWeb.SettingsLive => :settings,
    SuperXWeb.AccountsLive => :accounts,
    SuperXWeb.UpgradeLive => :upgrade,
    SuperXWeb.ConnectLive => :accounts
  }

  def on_mount(:default, _params, _session, socket) do
    socket =
      socket
      |> assign_new(:quota, fn ->
        case socket.assigns[:current_user] do
          nil -> nil
          user -> Billing.quota_snapshot(user)
        end
      end)
      |> assign(:active, Map.get(@nav_by_module, socket.view))
      |> attach_hook(:refresh_quota, :handle_info, &handle_quota_refresh/2)

    {:cont, socket}
  end

  # Any part of the app can broadcast a quota change and have the meter
  # update without threading assigns through the calling LiveView.
  defp handle_quota_refresh(:refresh_quota, socket) do
    case socket.assigns[:current_user] do
      nil -> {:halt, socket}
      user -> {:halt, assign(socket, :quota, Billing.quota_snapshot(user))}
    end
  end

  defp handle_quota_refresh(_msg, socket), do: {:cont, socket}
end
