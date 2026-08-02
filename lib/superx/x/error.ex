defmodule SuperX.X.Error do
  @moduledoc """
  Gives every X publisher the same retry boundary and user-facing errors.

  Client failures need a person's attention, while rate limits and server
  failures may recover. Keeping that distinction beside the response
  formatting stops one publishing surface retrying a rejection that another
  reports immediately.
  """

  # X documents 4xx responses as request/auth problems and recommends
  # retries for 429 and 5xx responses. A rejected publication should be
  # visible immediately rather than hidden behind five identical attempts.
  @doc "Whether retrying the same X request cannot succeed without a change."
  def permanent?({:http_error, status, _body}) when status in 400..499,
    do: status not in [408, 429]

  def permanent?({:unauthorized, _body}), do: true
  def permanent?({:media_missing, _key}), do: true
  def permanent?({:media_processing_failed, _error}), do: true
  def permanent?(_reason), do: false

  @doc "Turns an X failure into a short explanation safe to show the user."
  def describe({:http_error, status, body}), do: "X returned #{status}: #{summarise(body)}"
  def describe({:unauthorized, _}), do: "X rejected the request. Reconnect the account."
  def describe({:transport_error, _}), do: "Could not reach X."
  def describe({:media_missing, _key}), do: "An attached file is missing from local storage."

  def describe({:media_processing_failed, _error}),
    do: "X could not process an attached image or GIF."

  def describe(:media_processing_timeout), do: "X did not finish processing an attachment."
  def describe(other) when is_binary(other), do: other
  def describe(other), do: inspect(other)

  defp summarise(%{"detail" => detail}), do: detail
  defp summarise(%{"errors" => [%{"detail" => detail} | _]}), do: detail
  defp summarise(%{"errors" => [%{"message" => message} | _]}), do: message

  defp summarise(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) or is_list(decoded) -> summarise(decoded)
      _ -> String.slice(body, 0, 200)
    end
  end

  defp summarise(other), do: inspect(other) |> String.slice(0, 200)
end
