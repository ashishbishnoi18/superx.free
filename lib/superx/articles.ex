defmodule SuperX.Articles do
  @moduledoc """
  Long-form work owned by one connected account.

  The context stops at composition and review, and not for want of
  effort: X's API has no long-form endpoint. `POST /2/tweets` accepts
  text, media, polls, replies, quotes and a dozen niche flags, and
  nothing for an Article. There is no supported way to publish one
  programmatically, so anything here that claimed to would be pushing the
  user through the web composer by hand under another name.

  `record_published/2` is therefore the whole seam: it writes down an
  outcome that happened elsewhere and never attempts the network call. If
  X ever ships the endpoint, that is the function to grow.
  """

  import Ecto.Query

  alias SuperX.Accounts.{User, XAccount}
  alias SuperX.Articles.Article
  alias SuperX.Repo

  @doc "Articles for one account in one lifecycle state."
  def list_articles(%XAccount{} = account, status, opts \\ []) do
    Article
    |> where(x_account_id: ^account.id, status: ^status)
    |> order_by(^order_for(status))
    |> limit(^(opts[:limit] || 100))
    |> Repo.all()
  end

  defp order_for("published"), do: [desc: :published_at]
  defp order_for(_), do: [desc: :updated_at]

  @doc "Counts the account's articles for the status tabs."
  def counts(%XAccount{} = account) do
    counts =
      Article
      |> where(x_account_id: ^account.id)
      |> group_by([a], a.status)
      |> select([a], {a.status, count(a.id)})
      |> Repo.all()
      |> Map.new()

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
    article |> Article.changeset(attrs) |> Repo.update()
  end

  def change_article(%Article{} = article, attrs \\ %{}) do
    Article.changeset(article, attrs)
  end

  def delete_article(%Article{} = article), do: Repo.delete(article)

  @doc "Records a publication that an external integration has already confirmed."
  def record_published(%Article{} = article, attrs) do
    article |> Article.publication_changeset(attrs) |> Repo.update()
  end

  defp put_owner(changeset, user, account) do
    changeset
    |> Ecto.Changeset.put_change(:user_id, user.id)
    |> Ecto.Changeset.put_change(:x_account_id, account.id)
  end
end
