defmodule SuperX.Workers.PublishArticle do
  @moduledoc """
  Publishes one reviewed Article without letting retries duplicate it.

  The claim and job insert share a transaction, so a second click cannot
  buy another pair of X writes. Rate limits retain the claim while Oban
  waits for the reset window; permanent client failures return the Article
  to review with X's explanation.
  """

  use Oban.Worker,
    queue: :publishing,
    max_attempts: 5,
    unique: [period: :infinity, fields: [:worker, :args], states: :incomplete]

  import Ecto.Query

  require Logger

  alias Ecto.Multi
  alias SuperX.{Accounts, Articles, Repo}
  alias SuperX.Articles.Article
  alias SuperX.X.Error, as: XError

  @doc "Claims a ready Article and inserts its publishing job atomically."
  def enqueue(%Article{} = article) do
    claim = from(a in Article, where: a.id == ^article.id and a.status == "ready")

    Multi.new()
    |> Multi.update_all(:claim, claim, set: [status: "publishing", publish_error: nil])
    |> Multi.run(:article, &load_claimed(&1, &2, article.id))
    |> Oban.insert(:job, fn %{article: claimed} ->
      new(%{article_id: claimed.id})
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{article: claimed, job: job}} -> {:ok, claimed, job}
      {:error, :article, reason, _changes} -> {:error, reason}
      {:error, _operation, reason, _changes} -> {:error, reason}
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"article_id" => article_id}, attempt: attempt}) do
    case Repo.get(Article, article_id) do
      nil ->
        :ok

      %Article{status: "published"} ->
        :ok

      %Article{status: "publishing"} = article ->
        publish(article, attempt)

      %Article{} ->
        Logger.debug("Article #{article_id} is no longer claimed; skipping")
        :ok
    end
  end

  defp publish(%Article{} = article, attempt) do
    account = Accounts.get_x_account(article.x_account_id)

    with {:ok, token, _account} <- SuperX.X.Tokens.fresh_token(account),
         {:ok, published} <- Articles.publish(article, token) do
      announce(published, :published)
      Logger.info("Published Article #{article.id} as #{published.x_post_id}")
      :ok
    else
      {:error, :reauth_required} ->
        fail(article, "Your X connection expired. Reconnect the account to publish.")

      {:error, {:rate_limited, retry_after}} ->
        {:snooze, min(retry_after, 900)}

      {:error, reason} ->
        if XError.permanent?(reason) or attempt >= 5 do
          fail(article, XError.describe(reason))
        else
          {:error, reason}
        end
    end
  end

  defp fail(%Article{} = article, message) do
    case Articles.record_publish_failure(article, message) do
      {:ok, failed} ->
        announce(failed, {:error, message})
        :ok

      {:error, :already_published} ->
        :ok

      {:error, :already_claimed} ->
        case Repo.get(Article, article.id) do
          %Article{status: "ready"} = failed ->
            announce(failed, {:error, failed.publish_error || message})
            :ok

          _article ->
            {:error, :failure_state_changed}
        end

      {:error, reason} ->
        {:error, {:failure_record_failed, reason}}
    end
  end

  defp load_claimed(repo, %{claim: {1, _rows}}, article_id),
    do: {:ok, repo.get!(Article, article_id)}

  defp load_claimed(repo, %{claim: {0, _rows}}, article_id) do
    case repo.get(Article, article_id) do
      %Article{status: "published"} -> {:error, :already_published}
      %Article{} -> {:error, :already_claimed}
      nil -> {:error, :not_found}
    end
  end

  defp announce(article, result) do
    Phoenix.PubSub.broadcast(
      SuperX.PubSub,
      "articles:#{article.x_account_id}",
      {:article_publish_finished, article.id, result}
    )
  end
end
