defmodule SuperXWeb.ApiController do
  @moduledoc """
  The deliberately small read-only surface for scripts.

  Responses are projections of the same context reads used by LiveView,
  so the browser and API cannot quietly develop different definitions of
  the queue, shelf, or analytics.
  """

  use SuperXWeb, :controller

  alias SuperX.{Analytics, Content}
  alias SuperX.Accounts.XAccount
  alias SuperX.Content.{Generation, Post}

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
    |> json(%{error: "Connect an X account before reading this endpoint."})
  end

  defp invalid_parameter(conn, name, allowed) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "#{name} must be one of: #{Enum.join(allowed, ", ")}."})
  end
end
