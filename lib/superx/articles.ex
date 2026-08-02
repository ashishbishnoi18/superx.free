defmodule SuperX.Articles do
  @moduledoc """
  Long-form work owned by one connected account, from composition through
  publication.

  X splits publication into a private DraftJS draft and a separate publish
  call. The local `publishing` state closes the costly gap between a click
  and those two requests, while `record_published/2` remains the only path
  that can attach the returned X identifiers and make the prose read-only.
  """

  import Ecto.Query

  alias SuperX.Accounts.{User, XAccount}
  alias SuperX.Articles.Article
  alias SuperX.Repo
  alias SuperX.X
  alias SuperX.X.Error, as: XError

  @doc "Articles for one account in one lifecycle state."
  def list_articles(%XAccount{} = account, status, opts \\ []) do
    Article
    |> where(x_account_id: ^account.id)
    |> filter_status(status)
    |> order_by(^order_for(status))
    |> limit(^(opts[:limit] || 100))
    |> Repo.all()
  end

  defp order_for("published"), do: [desc: :published_at]
  defp order_for(_), do: [desc: :updated_at]

  defp filter_status(query, "ready"), do: where(query, [a], a.status in ["ready", "publishing"])
  defp filter_status(query, status), do: where(query, status: ^status)

  @doc "Counts the account's articles for the status tabs."
  def counts(%XAccount{} = account) do
    counts =
      Article
      |> where(x_account_id: ^account.id)
      |> group_by([a], a.status)
      |> select([a], {a.status, count(a.id)})
      |> Repo.all()
      |> Map.new()

    counts =
      Map.update(
        counts,
        "ready",
        Map.get(counts, "publishing", 0),
        &(&1 + Map.get(counts, "publishing", 0))
      )

    Map.new(Article.statuses(), &{&1, Map.get(counts, &1, 0)})
  end

  def get_article(%User{} = user, %XAccount{} = account, id) do
    with {:ok, id} <- Ecto.UUID.cast(id) do
      Repo.get_by(Article, id: id, user_id: user.id, x_account_id: account.id)
    else
      :error -> nil
    end
  end

  def create_article(
        %User{id: user_id} = user,
        %XAccount{user_id: user_id} = account,
        attrs
      ) do
    %Article{}
    |> Article.changeset(attrs)
    |> put_owner(user, account)
    |> Repo.insert()
  end

  def create_article(%User{}, %XAccount{}, _attrs), do: {:error, :account_mismatch}

  def update_article(%Article{} = article, attrs) do
    Repo.transaction(fn ->
      case Repo.get(Article, article.id, lock: "FOR UPDATE") do
        %Article{status: status} when status in ["publishing", "published"] ->
          Repo.rollback(:read_only)

        %Article{} = current ->
          case current |> Article.changeset(attrs) |> Repo.update() do
            {:ok, updated} -> updated
            {:error, changeset} -> Repo.rollback(changeset)
          end

        nil ->
          Repo.rollback(:not_found)
      end
    end)
    |> case do
      {:ok, updated} -> {:ok, updated}
      {:error, reason} -> {:error, reason}
    end
  end

  def change_article(%Article{} = article, attrs \\ %{}) do
    Article.changeset(article, attrs)
  end

  def delete_article(%Article{} = article), do: Repo.delete(article)

  @doc "Publishes a ready article through X and records the returned identifiers."
  def publish(%Article{status: "ready"} = article, access_token) do
    with {:ok, claimed} <- claim_for_publishing(article.id) do
      publish(claimed, access_token)
    end
  end

  def publish(%Article{status: "publishing"} = article, access_token) do
    with {:ok, draft} <- ensure_x_draft(article, access_token) do
      case X.publish_article(access_token, draft.x_article_id) do
        {:ok, post_id} ->
          record_published(draft, %{
            x_article_id: draft.x_article_id,
            x_post_id: post_id,
            permalink: "https://x.com/i/status/#{post_id}"
          })

        {:error, reason} ->
          publish_error(draft, reason)
      end
    else
      {:error, reason} -> publish_error(article, reason)
    end
  end

  def publish(%Article{status: "published"}, _access_token), do: {:error, :already_published}
  def publish(%Article{}, _access_token), do: {:error, :not_ready}

  @doc "Atomically reserves a ready article for one publisher."
  def claim_for_publishing(article_id) do
    query = from(a in Article, where: a.id == ^article_id and a.status == "ready")

    case Repo.update_all(query, set: [status: "publishing", publish_error: nil]) do
      {1, _rows} -> {:ok, Repo.get!(Article, article_id)}
      {0, _rows} -> publication_conflict(article_id)
    end
  end

  @doc "Returns a claimed article to review with a readable publishing failure."
  def record_publish_failure(%Article{} = article, message) do
    query = from(a in Article, where: a.id == ^article.id and a.status == "publishing")

    case Repo.update_all(query, set: [status: "ready", publish_error: message]) do
      {1, _rows} -> {:ok, Repo.get!(Article, article.id)}
      {0, _rows} -> publication_conflict(article.id)
    end
  end

  @doc "Records the identifiers returned by a confirmed X publication."
  def record_published(%Article{} = article, attrs) do
    article |> Article.publication_changeset(attrs) |> Repo.update()
  end

  defp ensure_x_draft(%Article{x_article_id: id} = article, _access_token)
       when is_binary(id) and id != "",
       do: {:ok, article}

  defp ensure_x_draft(%Article{} = article, access_token) do
    with {:ok, article_id} <- X.create_article_draft(access_token, article.title, article.body) do
      article
      |> Ecto.Changeset.change(x_article_id: article_id)
      |> Ecto.Changeset.unique_constraint(:x_article_id)
      |> Repo.update()
    end
  end

  defp publish_error(article, reason) do
    if XError.permanent?(reason) do
      case record_publish_failure(article, XError.describe(reason)) do
        {:ok, _article} -> {:error, reason}
        {:error, store_reason} -> {:error, {:failure_record_failed, reason, store_reason}}
      end
    else
      {:error, reason}
    end
  end

  defp publication_conflict(article_id) do
    case Repo.get(Article, article_id) do
      %Article{status: "published"} -> {:error, :already_published}
      %Article{} -> {:error, :already_claimed}
      nil -> {:error, :not_found}
    end
  end

  defp put_owner(changeset, user, account) do
    changeset
    |> Ecto.Changeset.put_change(:user_id, user.id)
    |> Ecto.Changeset.put_change(:x_account_id, account.id)
  end
end
