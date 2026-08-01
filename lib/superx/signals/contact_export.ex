defmodule SuperX.Signals.ContactExport do
  @moduledoc """
  CSV boundaries for moving contact data into an outreach workflow.

  Every row is encoded independently so the controller can pass database
  batches straight to the client. Formula-looking text is neutralised because
  handles, bios and notes came from people outside the spreadsheet's trust
  boundary.
  """

  @header [
    "display_name",
    "handle",
    "profile_url",
    "bio",
    "location",
    "followers",
    "following",
    "verified",
    "fit_score",
    "fit_reason",
    "status",
    "notes",
    "contacted_at",
    "source_agent",
    "source_post_url"
  ]

  def header, do: encode(@header)

  def rows(contacts) do
    contacts
    |> Enum.map(&row/1)
    |> IO.iodata_to_binary()
  end

  def row(contact) do
    source_url =
      if contact.source_post_id,
        do: "https://x.com/#{contact.handle}/status/#{contact.source_post_id}"

    encode([
      contact.display_name,
      contact.handle,
      "https://x.com/#{contact.handle}",
      contact.bio,
      contact.location,
      contact.followers_count,
      contact.following_count,
      contact.verified,
      contact.score,
      contact.reason,
      contact.status,
      contact.notes,
      contact.contacted_at,
      contact.agent_name,
      source_url
    ])
  end

  defp encode(values), do: [Enum.map_join(values, ",", &cell/1), "\r\n"]

  defp cell(nil), do: ""
  defp cell(value) when is_integer(value), do: Integer.to_string(value)
  defp cell(value) when is_boolean(value), do: to_string(value)
  defp cell(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp cell(value) when is_binary(value) do
    value =
      value
      |> String.replace(<<0>>, "")
      |> neutralise_formula()
      |> String.replace("\"", "\"\"")

    "\"#{value}\""
  end

  defp neutralise_formula(value) do
    if Regex.match?(~r/^\s*[=+\-@]/u, value), do: "'" <> value, else: value
  end
end
