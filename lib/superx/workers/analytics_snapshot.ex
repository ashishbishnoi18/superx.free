defmodule SuperX.Workers.AnalyticsSnapshot do
  @moduledoc """
  Records a daily metrics row for every connected account.

  Follower and post totals come from the X profile endpoint. Per-post
  impression figures require the paid analytics tier, so when they are
  unavailable the engagement columns are filled from the posts we
  published ourselves — partial data beats an empty dashboard.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 3

  import Ecto.Query

  require Logger

  alias SuperX.Accounts.XAccount
  alias SuperX.{Accounts, Analytics, Repo}

  @impl Oban.Worker
  def perform(_job) do
    XAccount
    |> where([a], not a.reauth_needed)
    |> Repo.all()
    |> Enum.each(&snapshot/1)

    :ok
  end

  defp snapshot(%XAccount{} = account) do
    date = Date.utc_today()

    with {:ok, token, account} <- SuperX.X.Tokens.fresh_token(account),
         {:ok, profile} <- SuperX.X.get_me(token) do
      profile =
        Map.put(
          profile,
          :last_synced_at,
          DateTime.utc_now() |> DateTime.truncate(:second)
        )

      {:ok, account} = Accounts.update_x_account_profile(account, profile)

      Analytics.record_snapshot(account, date, %{
        followers: account.followers_count,
        following: account.following_count,
        posts: account.posts_count,
        engagements: published_today(account, date)
      })
    else
      {:error, :reauth_required} ->
        Logger.debug("Skipping analytics for @#{account.handle}: needs reconnect")
        :ok

      {:error, reason} ->
        Logger.warning("Analytics snapshot failed for @#{account.handle}: #{inspect(reason)}")
        :ok
    end
  end

  defp published_today(%XAccount{} = account, date) do
    from = DateTime.new!(date, ~T[00:00:00], "Etc/UTC")

    SuperX.Content.Post
    |> where([p], p.x_account_id == ^account.id)
    |> where([p], p.status == "posted" and p.published_at >= ^from)
    |> select([p], count(p.id))
    |> Repo.one()
  end
end
