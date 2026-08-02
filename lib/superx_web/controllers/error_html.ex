defmodule SuperXWeb.ErrorHTML do
  @moduledoc """
  This module is invoked by your endpoint in case of errors on HTML requests.

  See config/config.exs.
  """
  use SuperXWeb, :html

  embed_templates "error_html/*"

  # Statuses without their own template fall back to the generic status
  # message, e.g. "405.html" becomes "Method Not Allowed".
  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end
end
