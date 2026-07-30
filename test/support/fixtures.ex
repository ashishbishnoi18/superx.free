defmodule SuperX.Fixtures do
  @moduledoc """
  Test fixtures for users, connected accounts, and content.
  """

  alias SuperX.Accounts.Connect

  def user_fixture(attrs \\ %{}) do
    handle = attrs[:handle] || "user#{System.unique_integer([:positive])}"

    {:ok, user, account} =
      Connect.sign_in(
        %{
          x_user_id: attrs[:x_user_id] || "x-#{System.unique_integer([:positive])}",
          handle: handle,
          display_name: attrs[:display_name] || "Test #{handle}",
          followers_count: attrs[:followers_count] || 100,
          following_count: 50,
          posts_count: 10
        },
        %{
          access_token: attrs[:access_token] || "access-token",
          refresh_token: attrs[:refresh_token] || "refresh-token",
          token_expires_at:
            attrs[:token_expires_at] ||
              DateTime.utc_now() |> DateTime.add(7200) |> DateTime.truncate(:second),
          scopes: ["tweet.read", "tweet.write"]
        }
      )

    %{user: user, account: account}
  end

  def corpus_post_fixture(attrs \\ %{}) do
    defaults = %{
      x_post_id: "post-#{System.unique_integer([:positive])}",
      author_handle: "someone",
      author_name: "Someone",
      author_followers: 10_000,
      text: "A post that did unusually well.",
      likes: 5_000,
      reposts: 800,
      replies: 120,
      posted_at: DateTime.utc_now() |> DateTime.add(-3600) |> DateTime.truncate(:second)
    }

    attrs = Map.merge(defaults, Map.new(attrs))

    %SuperX.Content.CorpusPost{}
    |> SuperX.Content.CorpusPost.changeset(attrs)
    |> SuperX.Repo.insert!()
  end
end
