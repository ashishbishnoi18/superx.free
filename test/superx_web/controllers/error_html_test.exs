defmodule SuperXWeb.ErrorHTMLTest do
  use SuperXWeb.ConnCase, async: true

  import Phoenix.Template, only: [render_to_string: 4]

  test "renders 404.html" do
    html = render_to_string(SuperXWeb.ErrorHTML, "404", "html", [])

    assert html =~ "Page not found"
    # An error page must never be indexed as though it were content.
    assert html =~ ~s(<meta name="robots" content="noindex">)
  end

  test "renders 500.html" do
    html = render_to_string(SuperXWeb.ErrorHTML, "500", "html", [])

    assert html =~ "Something went wrong"
    assert html =~ ~s(<meta name="robots" content="noindex">)
  end
end
