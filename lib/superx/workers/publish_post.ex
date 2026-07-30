defmodule SuperX.Workers.PublishPost do
  @moduledoc """
  Publishes one post (or thread) to X.

  Correctness rules that matter here:

    * The post is claimed with a conditional status update, so two
      dispatcher ticks can never publish it twice.
    * A partially published thread records the ids that did go out and
      then stops. Retrying would duplicate the first half, which is worse
      than a visible failure the user can finish by hand.
    * Rate limits reschedule with the reset window rather than counting
      as a failed attempt.
  """

  use Oban.Worker, queue: :publishing, max_attempts: 5

  require Logger

  alias SuperX.{Accounts, Content, Repo}
  alias SuperX.Content.Post

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"post_id" => post_id}, attempt: attempt}) do
    case Content.claim_for_publishing(post_id) do
      {:ok, post} ->
        publish(post, attempt)

      # Another tick got there first, or the user cancelled it.
      {:error, :already_claimed} ->
        Logger.debug("Post #{post_id} was already claimed; skipping")
        :ok
    end
  end

  defp publish(%Post{} = post, attempt) do
    account = Accounts.get_x_account(post.x_account_id)

    with {:ok, token, _account} <- SuperX.X.Tokens.fresh_token(account),
         {:ok, x_post_ids} <- send_to_x(token, post) do
      {:ok, _post} = Content.mark_published(post, x_post_ids)
      Logger.info("Published post #{post.id} as #{inspect(x_post_ids)}")
      :ok
    else
      {:error, :reauth_required} ->
        fail(post, "Your X connection expired. Reconnect the account to publish.")

      {:error, {:rate_limited, retry_after}} ->
        # Put it back in the queue and try again after the window resets.
        requeue(post)
        {:snooze, min(retry_after, 900)}

      {:error, reason, published_ids} ->
        # Partial thread: record what went out, then stop.
        Logger.error("Thread #{post.id} failed partway: #{inspect(reason)}")

        post
        |> Ecto.Changeset.change(x_post_ids: published_ids)
        |> Repo.update!()

        fail(
          post,
          "Published #{length(published_ids)} of #{length(post.segments)} posts, then failed: #{describe(reason)}"
        )

      {:error, reason} ->
        if attempt >= 5 do
          fail(post, describe(reason))
        else
          # Let Oban retry with backoff; the post goes back to scheduled so
          # the queue still shows it as pending.
          requeue(post)
          {:error, reason}
        end
    end
  end

  defp send_to_x(token, %Post{segments: [single]} = post) do
    case SuperX.X.create_post(token, single["text"],
           reply_to: post.reply_to_x_post_id,
           media_ids: single["media_ids"] || []
         ) do
      {:ok, id} -> {:ok, [id]}
      error -> error
    end
  end

  defp send_to_x(token, %Post{segments: segments} = post) do
    SuperX.X.create_thread(token, segments, reply_to: post.reply_to_x_post_id)
  end

  defp requeue(%Post{} = post) do
    post |> Ecto.Changeset.change(status: "scheduled") |> Repo.update!()
  end

  defp fail(%Post{} = post, message) do
    {:ok, _} = Content.mark_failed(post, message)
    # Returning :ok stops Oban retrying: the failure is now the user's to
    # act on, and repeated attempts would only re-fail.
    :ok
  end

  defp describe({:http_error, status, body}), do: "X returned #{status}: #{summarise(body)}"
  defp describe({:unauthorized, _}), do: "X rejected the request. Reconnect the account."
  defp describe({:transport_error, _}), do: "Could not reach X."
  defp describe(other) when is_binary(other), do: other
  defp describe(other), do: inspect(other)

  defp summarise(%{"detail" => detail}), do: detail
  defp summarise(%{"errors" => [%{"message" => message} | _]}), do: message
  defp summarise(body) when is_binary(body), do: String.slice(body, 0, 200)
  defp summarise(other), do: inspect(other) |> String.slice(0, 200)
end
