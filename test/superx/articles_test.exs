defmodule SuperX.ArticlesTest do
  use SuperX.DataCase, async: true

  import SuperX.Fixtures

  alias SuperX.Articles
  alias SuperX.Articles.Article

  describe "composition" do
    test "derives word count instead of trusting submitted data" do
      %{user: user, account: account} = user_fixture()

      assert {:ok, article} =
               Articles.create_article(user, account, %{
                 title: "A measured argument",
                 body: "One\n\ntwo   three",
                 word_count: 99_999
               })

      assert article.user_id == user.id
      assert article.x_account_id == account.id
      assert article.word_count == 3
      assert article.status == "draft"
    end

    test "ready articles require a title and body" do
      %{user: user, account: account} = user_fixture()

      assert {:error, changeset} =
               Articles.create_article(user, account, %{status: "ready", body: ""})

      assert "can't be blank" in errors_on(changeset).title
      assert "can't be blank" in errors_on(changeset).body
    end

    test "reads never cross user or account ownership" do
      %{user: owner, account: account} = user_fixture()
      %{user: other_user, account: other_account} = user_fixture()

      {:ok, article} = Articles.create_article(owner, account, %{title: "Private draft"})

      assert Articles.get_article(owner, account, article.id) == article
      assert Articles.get_article(other_user, other_account, article.id) == nil
      assert Articles.create_article(owner, other_account, %{}) == {:error, :account_mismatch}
    end

    test "lists and counts lifecycle states within one account" do
      %{user: user, account: account} = user_fixture()

      {:ok, _draft} = Articles.create_article(user, account, %{title: "Draft"})

      {:ok, ready} =
        Articles.create_article(user, account, %{
          title: "Ready",
          body: "Finished prose.",
          status: "ready"
        })

      assert [listed] = Articles.list_articles(account, "ready")
      assert listed.id == ready.id
      assert Articles.counts(account) == %{"draft" => 1, "published" => 0, "ready" => 1}
    end
  end

  describe "publication seam" do
    test "only records a confirmed destination" do
      %{user: user, account: account} = user_fixture()

      {:ok, article} =
        Articles.create_article(user, account, %{
          title: "Complete",
          body: "A complete article.",
          status: "ready"
        })

      assert {:error, changeset} = Articles.record_published(article, %{})
      assert "or an X article id is required" in errors_on(changeset).permalink

      assert {:ok, published} =
               Articles.record_published(article, %{
                 x_article_id: "x-article-1",
                 permalink: "https://x.com/i/article/x-article-1"
               })

      assert %Article{status: "published"} = published
      assert published.published_at
      assert published.x_article_id == "x-article-1"
    end
  end
end
