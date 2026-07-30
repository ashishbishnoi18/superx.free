defmodule SuperX.X do
  @moduledoc """
  Client for the X API v2.

  Scope is deliberately narrow: **writes only** — OAuth, publishing, and
  DMs. Bulk reads (the corpus, watch agents) go through the scraper
  instead, because API read quotas make them impossible at any workable
  price.

  Every call takes an access token rather than an account struct, so this
  module stays free of database concerns. `SuperX.X.Tokens` handles
  refresh and hands a live token down.
  """

  require Logger

  @doc "The URL to send a user to in order to authorise the app."
  def authorize_url(state, code_challenge) do
    query =
      URI.encode_query(%{
        "response_type" => "code",
        "client_id" => config(:client_id),
        "redirect_uri" => config(:redirect_uri),
        "scope" => Enum.join(config(:scopes), " "),
        "state" => state,
        "code_challenge" => code_challenge,
        "code_challenge_method" => "S256"
      })

    config(:oauth_authorize_url) <> "?" <> query
  end

  @doc """
  Exchanges an authorisation code for tokens.

  Returns `{:ok, %{access_token:, refresh_token:, token_expires_at:, scopes:}}`.
  """
  def exchange_code(code, code_verifier) do
    form = %{
      "grant_type" => "authorization_code",
      "code" => code,
      "redirect_uri" => config(:redirect_uri),
      "code_verifier" => code_verifier,
      "client_id" => config(:client_id)
    }

    post_token(form)
  end

  @doc "Trades a refresh token for a fresh access token."
  def refresh_token(refresh_token) do
    form = %{
      "grant_type" => "refresh_token",
      "refresh_token" => refresh_token,
      "client_id" => config(:client_id)
    }

    post_token(form)
  end

  @doc "Revokes a token when a user disconnects an account."
  def revoke_token(token) do
    request(:post, "/oauth2/revoke",
      form: %{"token" => token, "client_id" => config(:client_id)},
      auth: basic_auth()
    )
  end

  # --- Users ---------------------------------------------------------------

  @user_fields "id,name,username,profile_image_url,description,public_metrics,verified"

  @doc "Fetches the profile of the authenticated user."
  def get_me(access_token) do
    case request(:get, "/users/me", params: %{"user.fields" => @user_fields}, token: access_token) do
      {:ok, %{"data" => data}} -> {:ok, normalize_user(data)}
      {:ok, other} -> {:error, {:unexpected_response, other}}
      error -> error
    end
  end

  @doc "Fetches recent posts by a user, used to seed their voice profile."
  def get_user_posts(access_token, x_user_id, opts \\ []) do
    params = %{
      "max_results" => opts[:limit] || 100,
      "tweet.fields" => "created_at,public_metrics,text,lang,referenced_tweets",
      "exclude" => "retweets,replies"
    }

    case request(:get, "/users/#{x_user_id}/tweets", params: params, token: access_token) do
      {:ok, %{"data" => posts}} -> {:ok, posts}
      # An account with no posts yet returns no `data` key at all.
      {:ok, _no_data} -> {:ok, []}
      error -> error
    end
  end

  # --- Publishing ----------------------------------------------------------

  @doc """
  Publishes a single post. Pass `reply_to` to attach it to an existing
  post, which is how threads are built.
  """
  def create_post(access_token, text, opts \\ []) do
    body =
      %{"text" => text}
      |> maybe_put_reply(opts[:reply_to])
      |> maybe_put_media(opts[:media_ids])

    case request(:post, "/tweets", json: body, token: access_token) do
      {:ok, %{"data" => %{"id" => id}}} -> {:ok, id}
      {:ok, other} -> {:error, {:unexpected_response, other}}
      error -> error
    end
  end

  @doc """
  Publishes an ordered list of segments as a thread, chaining each post
  as a reply to the previous one.

  On partial failure it returns the ids that did publish alongside the
  error, so the caller can record what actually went out rather than
  retrying the whole thread and double-posting.
  """
  def create_thread(access_token, segments, opts \\ []) do
    initial_reply_to = opts[:reply_to]

    Enum.reduce_while(segments, {:ok, [], initial_reply_to}, fn segment, {:ok, ids, reply_to} ->
      text = segment["text"] || segment[:text] || ""
      media_ids = segment["media_ids"] || segment[:media_ids] || []

      case create_post(access_token, text, reply_to: reply_to, media_ids: media_ids) do
        {:ok, id} ->
          {:cont, {:ok, ids ++ [id], id}}

        {:error, reason} ->
          {:halt, {:error, reason, ids}}
      end
    end)
    |> case do
      {:ok, ids, _last} -> {:ok, ids}
      {:error, reason, published} -> {:error, reason, published}
    end
  end

  defp maybe_put_reply(body, nil), do: body

  defp maybe_put_reply(body, reply_to),
    do: Map.put(body, "reply", %{"in_reply_to_tweet_id" => reply_to})

  defp maybe_put_media(body, nil), do: body
  defp maybe_put_media(body, []), do: body
  defp maybe_put_media(body, ids), do: Map.put(body, "media", %{"media_ids" => ids})

  # --- Configuration -------------------------------------------------------

  @doc "Whether X OAuth credentials are configured at all."
  def configured? do
    is_binary(config(:client_id)) and config(:client_id) != "" and
      is_binary(config(:client_secret)) and config(:client_secret) != ""
  end

  defp config(key) do
    Application.get_env(:superx, __MODULE__, [])[key]
  end

  defp basic_auth do
    {:basic, "#{config(:client_id)}:#{config(:client_secret)}"}
  end

  # --- HTTP ----------------------------------------------------------------

  defp post_token(form) do
    case request(:post, "/oauth2/token", form: form, auth: basic_auth()) do
      {:ok, %{"access_token" => access_token} = body} ->
        {:ok,
         %{
           access_token: access_token,
           refresh_token: body["refresh_token"],
           token_expires_at: expires_at(body["expires_in"]),
           scopes: String.split(body["scope"] || "", " ", trim: true)
         }}

      {:ok, other} ->
        {:error, {:unexpected_response, other}}

      error ->
        error
    end
  end

  defp expires_at(nil), do: nil

  defp expires_at(seconds) when is_integer(seconds) do
    DateTime.utc_now() |> DateTime.add(seconds, :second) |> DateTime.truncate(:second)
  end

  defp normalize_user(data) do
    metrics = data["public_metrics"] || %{}

    %{
      x_user_id: data["id"],
      handle: data["username"],
      display_name: data["name"],
      avatar_url: normalize_avatar(data["profile_image_url"]),
      description: data["description"],
      followers_count: metrics["followers_count"] || 0,
      following_count: metrics["following_count"] || 0,
      posts_count: metrics["tweet_count"] || 0
    }
  end

  # X returns a 48px thumbnail by default; the app shows larger avatars.
  defp normalize_avatar(nil), do: nil
  defp normalize_avatar(url), do: String.replace(url, "_normal.", "_400x400.")

  defp request(method, path, opts) do
    url =
      case path do
        "/oauth2/token" -> Application.get_env(:superx, __MODULE__)[:oauth_token_url]
        _ -> config(:api_base) <> path
      end

    req_opts =
      [method: method, url: url, receive_timeout: 20_000, retry: :transient, max_retries: 2]
      |> put_opt(:params, opts[:params])
      |> put_opt(:json, opts[:json])
      |> put_opt(:form, opts[:form])
      |> put_auth(opts)

    case Req.request(req_opts) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %Req.Response{status: 401, body: body}} ->
        {:error, {:unauthorized, body}}

      {:ok, %Req.Response{status: 429, headers: headers}} ->
        {:error, {:rate_limited, reset_after(headers)}}

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.warning("X API #{method} #{path} returned #{status}: #{inspect(body)}")
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, {:transport_error, reason}}
    end
  end

  defp put_opt(opts, _key, nil), do: opts
  defp put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp put_auth(req_opts, opts) do
    cond do
      token = opts[:token] -> Keyword.put(req_opts, :auth, {:bearer, token})
      auth = opts[:auth] -> Keyword.put(req_opts, :auth, auth)
      true -> req_opts
    end
  end

  # Seconds until the rate limit window resets, for job backoff.
  defp reset_after(headers) do
    with [value | _] <- Map.get(headers, "x-rate-limit-reset", []),
         {epoch, _} <- Integer.parse(value) do
      max(epoch - System.system_time(:second), 1)
    else
      _ -> 900
    end
  end
end
