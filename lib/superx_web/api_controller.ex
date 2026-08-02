defmodule SuperXWeb.ApiController do
  @moduledoc """
  The deliberately small surface for scripts.

  Reads and writes go through the same content context used by LiveView, so
  the browser and API cannot quietly develop different lifecycle rules.
  Writes stop at drafts and scheduling; there is no path from this controller
  to the publishing worker or X.
  """

  use SuperXWeb, :controller

  alias SuperX.{Analytics, Content}
  alias SuperX.Accounts.XAccount
  alias SuperX.Content.{Generation, Post}
  alias SuperXWeb.CoreComponents

  @analytics_ranges [7, 30, 90]

  def queue(conn, params) do
    with {:ok, account} <- current_account(conn),
         {:ok, status} <- queue_status(params["status"]) do
      posts = Content.list_posts(account, status)

      json(conn, %{
        account: account_data(account),
        status: status,
        posts: Enum.map(posts, &post_data/1)
      })
    else
      {:error, :no_account} -> no_account(conn)
      {:error, :invalid_status} -> invalid_parameter(conn, "status", Post.statuses())
    end
  end

  def shelf(conn, _params) do
    with {:ok, account} <- current_account(conn) do
      json(conn, %{
        account: account_data(account),
        counts: Content.shelf_counts(account),
        drafts: account |> Content.list_shelf() |> Enum.map(&generation_data/1)
      })
    else
      {:error, :no_account} -> no_account(conn)
    end
  end

  def analytics(conn, params) do
    with {:ok, account} <- current_account(conn),
         {:ok, days} <- analytics_days(params["days"]) do
      json(conn, %{
        account: account_data(account),
        days: days,
        summary: Analytics.summary(account, days)
      })
    else
      {:error, :no_account} -> no_account(conn)
      {:error, :invalid_days} -> invalid_parameter(conn, "days", @analytics_ranges)
    end
  end

  def create_post(conn, params) do
    with {:ok, account} <- current_account(conn),
         {:ok, post} <-
           Content.create_post(conn.assigns.current_user, account, draft_attrs(params)) do
      conn
      |> put_status(:created)
      |> json(%{post: post_data(post)})
    else
      {:error, :no_account} -> no_account(conn)
      {:error, %Ecto.Changeset{} = changeset} -> validation_errors(conn, changeset)
    end
  end

  def schedule_post(conn, %{"id" => id} = params) do
    with {:ok, account} <- current_account(conn),
         {:ok, %Post{status: "draft"} = post} <- selected_post(conn, account, id),
         {:ok, schedule_opts} <- schedule_options(params["at"]),
         {:ok, scheduled} <- Content.schedule_post(post, schedule_opts) do
      json(conn, %{post: post_data(scheduled)})
    else
      {:error, :no_account} -> no_account(conn)
      {:error, :not_found} -> post_not_found(conn)
      {:ok, %Post{}} -> post_not_draft(conn)
      {:error, :invalid_time} -> invalid_time(conn)
      {:error, :no_slots} -> no_slots(conn)
      {:error, :slot_taken} -> slot_taken(conn)
      {:error, %Ecto.Changeset{} = changeset} -> validation_errors(conn, changeset)
    end
  end

  def delete_post(conn, %{"id" => id}) do
    with {:ok, account} <- current_account(conn),
         {:ok, post} <- selected_post(conn, account, id),
         {:ok, _deleted} <- Content.delete_post(post) do
      send_resp(conn, :no_content, "")
    else
      {:error, :no_account} -> no_account(conn)
      {:error, :not_found} -> post_not_found(conn)
    end
  end

  defp current_account(%Plug.Conn{assigns: %{current_x_account: %XAccount{} = account}}),
    do: {:ok, account}

  defp current_account(_conn), do: {:error, :no_account}

  defp queue_status(nil), do: {:ok, "scheduled"}

  defp queue_status(status) do
    if status in Post.statuses(), do: {:ok, status}, else: {:error, :invalid_status}
  end

  defp analytics_days(nil), do: {:ok, 30}

  defp analytics_days(value) when is_binary(value) do
    with {days, ""} <- Integer.parse(value),
         true <- days in @analytics_ranges do
      {:ok, days}
    else
      _ -> {:error, :invalid_days}
    end
  end

  defp analytics_days(_value), do: {:error, :invalid_days}

  defp draft_attrs(params) do
    %{
      segments: params["segments"] || [],
      tags: params["tags"] || [],
      status: "draft",
      source: "manual"
    }
  end

  defp selected_post(conn, account, id) do
    case Content.get_post(conn.assigns.current_user, account, id) do
      %Post{} = post -> {:ok, post}
      _post -> {:error, :not_found}
    end
  end

  defp schedule_options(nil), do: {:ok, []}

  defp schedule_options(encoded_at) when is_binary(encoded_at) do
    with {:ok, parsed_at, _offset} <- DateTime.from_iso8601(encoded_at),
         at = DateTime.truncate(parsed_at, :second),
         now = DateTime.utc_now() |> DateTime.truncate(:second),
         :gt <- DateTime.compare(at, now) do
      {:ok, [at: at]}
    else
      _reason -> {:error, :invalid_time}
    end
  end

  defp schedule_options(_value), do: {:error, :invalid_time}

  defp account_data(account) do
    %{
      id: account.id,
      handle: account.handle,
      display_name: account.display_name
    }
  end

  defp post_data(post) do
    Map.take(post, [
      :id,
      :status,
      :segments,
      :scheduled_at,
      :published_at,
      :permalink,
      :error,
      :failed_at,
      :source,
      :tags,
      :inserted_at,
      :updated_at
    ])
  end

  defp generation_data(%Generation{} = generation) do
    Map.take(generation, [
      :id,
      :segments,
      :kind,
      :source_likes,
      :score,
      :inserted_at
    ])
  end

  defp no_account(conn) do
    conn
    |> put_status(:conflict)
    |> json(%{error: "Connect an X account before using this endpoint."})
  end

  defp invalid_parameter(conn, name, allowed) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "#{name} must be one of: #{Enum.join(allowed, ", ")}."})
  end

  defp validation_errors(conn, changeset) do
    errors = Ecto.Changeset.traverse_errors(changeset, &CoreComponents.translate_error/1)

    conn
    |> put_status(:unprocessable_entity)
    |> json(%{errors: errors})
  end

  defp post_not_found(conn) do
    conn
    |> put_status(:not_found)
    |> json(%{error: "That post does not exist."})
  end

  defp post_not_draft(conn) do
    conn
    |> put_status(:conflict)
    |> json(%{error: "Only a draft can be scheduled."})
  end

  defp invalid_time(conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "at must be a future ISO 8601 datetime."})
  end

  defp no_slots(conn) do
    conn
    |> put_status(:conflict)
    |> json(%{error: "Choose some posting times first."})
  end

  defp slot_taken(conn) do
    conn
    |> put_status(:conflict)
    |> json(%{error: "That opening was filled while you were choosing."})
  end
end
