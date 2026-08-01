defmodule SuperXWeb.ContactListShareHTML do
  @moduledoc """
  The public circle keeps the contact list useful without exposing the
  signed-in shell or the owner's qualification and outreach records.
  """

  use SuperXWeb, :html

  embed_templates "contact_list_share_html/*"
end
