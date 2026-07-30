defmodule SuperXWeb.Plugs.RawBody do
  @moduledoc """
  Caches the raw request body so webhook signatures can be verified.

  Stripe signs the exact bytes it sent. Re-encoding the parsed params
  produces different bytes (key order, whitespace, number formatting), so
  the signature would never match. This body reader stashes the original
  on the conn during parsing.

  Only applied to webhook paths — holding full request bodies in memory
  everywhere would be wasteful.
  """

  @webhook_paths ["/webhooks/"]

  def read_body(conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} -> {:ok, body, maybe_cache(conn, body)}
      {:more, body, conn} -> {:more, body, maybe_cache(conn, body)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_cache(conn, body) do
    if webhook?(conn.request_path) do
      Plug.Conn.assign(conn, :raw_body, (conn.assigns[:raw_body] || "") <> body)
    else
      conn
    end
  end

  defp webhook?(path), do: Enum.any?(@webhook_paths, &String.starts_with?(path, &1))
end
