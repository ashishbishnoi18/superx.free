defmodule SuperX.Workers.ShelfTopUp do
  @moduledoc """
  Refills each account's Ready to Post shelf overnight, so there is
  something waiting when the user opens the app.

  Accounts with no voice profile are skipped — generating from an empty
  voice produces generic output that teaches the user the product doesn't
  work.
  """

  use Oban.Worker, queue: :generation, max_attempts: 2

  import Ecto.Query

  require Logger

  alias SuperX.Accounts.{User, XAccount}
  alias SuperX.{Accounts, Content, Repo}
  alias SuperX.Content.Writer

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"x_account_id" => id}}) do
    case Accounts.get_x_account(id) do
      nil -> :ok
      account -> top_up(account)
    end
  end

  def perform(_job) do
    if SuperX.AI.configured?() do
      XAccount
      |> where([a], not a.reauth_needed)
      |> Repo.all()
      |> Enum.each(&top_up/1)
    else
      Logger.info("Skipping shelf top-up: no LLM configured")
    end

    :ok
  end

  defp top_up(%XAccount{} = account) do
    user = Repo.get!(User, account.user_id)

    case Content.get_voice_profile(account) do
      %{about: about} when is_binary(about) and about != "" ->
        targets = targets_for(user)

        case Writer.top_up(user, account, targets) do
          {:ok, 0} ->
            :ok

          {:ok, count} ->
            Logger.info("Generated #{count} shelf item(s) for @#{account.handle}")
            # Nudge any open session to refresh.
            Phoenix.PubSub.broadcast(SuperX.PubSub, "shelf:#{account.id}", :shelf_updated)

          {:error, reason} ->
            Logger.warning("Shelf top-up failed for @#{account.handle}: #{inspect(reason)}")
        end

      _ ->
        Logger.debug("Skipping @#{account.handle}: no voice profile yet")
        :ok
    end
  end

  # How many of each kind to keep on the shelf, from the user's settings.
  defp targets_for(%User{} = user) do
    mix = Accounts.setting(user, "daily_mix") || %{}

    Map.new(mix, fn {kind, count} -> {kind, count} end)
  end
end
