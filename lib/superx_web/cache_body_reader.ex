defmodule SuperXWeb.CacheBodyReader do
  @moduledoc """
  Keeps the raw request body for webhook routes.

  A Stripe signature covers the exact bytes sent, so re-encoding the parsed
  map and signing that gives a different digest and every event is rejected.
  The body is cached only under `/webhooks`, because holding a copy of every
  upload in memory to serve one endpoint would be a poor trade.
  """

  @webhook_prefix ["webhooks"]

  def read_body(%{path_info: [prefix | _rest]} = conn, opts) when prefix in @webhook_prefix do
    {:ok, body, conn} = Plug.Conn.read_body(conn, opts)
    {:ok, body, Plug.Conn.assign(conn, :raw_body, body)}
  end

  def read_body(conn, opts), do: Plug.Conn.read_body(conn, opts)
end
