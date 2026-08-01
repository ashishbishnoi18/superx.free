defmodule SuperXWeb.ContactExportController do
  use SuperXWeb, :controller

  alias SuperX.Accounts
  alias SuperX.Repo
  alias SuperX.Signals
  alias SuperX.Signals.ContactExport

  def show(conn, params) do
    account = Accounts.current_x_account(conn.assigns.current_user)

    with %{} = account <- account,
         {:ok, list} <- export_list(account, params["list"]) do
      stream(conn, account, list)
    else
      nil -> redirect(conn, to: ~p"/connect")
      {:error, :not_found} -> send_resp(conn, 404, "Not found")
    end
  end

  defp export_list(_account, nil), do: {:ok, nil}
  defp export_list(_account, ""), do: {:ok, nil}

  defp export_list(account, id) do
    case Signals.get_contact_list(account, id) do
      nil -> {:error, :not_found}
      list -> {:ok, list}
    end
  end

  defp stream(conn, account, list) do
    conn =
      conn
      |> put_resp_content_type("text/csv", "utf-8")
      |> put_resp_header("cache-control", "private, no-store")
      |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename(list)}"))
      |> send_chunked(200)

    with {:ok, conn} <- chunk(conn, ContactExport.header()),
         {:ok, conn} <- stream_rows(conn, account, list) do
      conn
    else
      {:error, _reason} -> conn
    end
  end

  defp stream_rows(conn, account, list) do
    Repo.transaction(
      fn ->
        account
        |> Signals.stream_contact_export(list)
        |> Stream.chunk_every(500)
        |> Enum.reduce_while(conn, fn contacts, conn ->
          case chunk(conn, ContactExport.rows(contacts)) do
            {:ok, conn} -> {:cont, conn}
            {:error, _reason} -> {:halt, conn}
          end
        end)
      end,
      timeout: :infinity
    )
  end

  defp filename(nil), do: "contacts.csv"

  defp filename(list) do
    slug =
      list.name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")

    if slug == "", do: "contacts.csv", else: "#{slug}-contacts.csv"
  end
end
