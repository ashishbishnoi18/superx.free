defmodule SuperXWeb.PageControllerTest do
  use SuperXWeb.ConnCase, async: true

  import SuperX.Fixtures

  test "renders the marketing page for signed-out visitors", %{conn: conn} do
    document = conn |> get(~p"/") |> html_response(200) |> LazyHTML.from_document()

    assert LazyHTML.text(LazyHTML.query(document, "#landing-title")) =~ "Grow on 𝕏 without"
    assert LazyHTML.text(LazyHTML.query(document, "#what-it-does")) =~ "Draft in your voice"
    assert Enum.count(LazyHTML.query(document, "h1")) == 1
    assert Enum.count(LazyHTML.query(document, "#landing-nav")) == 1
    assert Enum.count(LazyHTML.query(document, "main section")) == 6
  end

  test "states both hosted prices and that paying gates nothing" do
    # The page is the only place a visitor sees the price before checkout, so
    # a silent copy change here is a pricing change nobody reviewed.
    document = build_conn() |> get(~p"/") |> html_response(200) |> LazyHTML.from_document()
    pricing = LazyHTML.text(LazyHTML.query(document, "#pricing"))

    assert pricing =~ "$5"
    assert pricing =~ "$9"
    assert pricing =~ "Bring your own keys"
    assert pricing =~ "Keys included"
    assert pricing =~ "unlocks"
    assert Enum.count(LazyHTML.query(document, "a[href='#pricing']")) == 1
  end

  test "explains what's missing when X sign-in isn't configured", %{conn: conn} do
    document = conn |> get(~p"/") |> html_response(200) |> LazyHTML.from_document()

    # The test environment has no X credentials, so the sign-in button is
    # replaced by setup guidance rather than a dead link.
    assert LazyHTML.text(LazyHTML.query(document, "#x-configuration-help")) =~
             "X sign-in isn't configured yet"

    assert Enum.empty?(LazyHTML.query(document, "a[href='/auth/x']"))
  end

  test "renders discoverability metadata with landing-page overrides", %{conn: conn} do
    document = conn |> get(~p"/") |> html_response(200) |> LazyHTML.from_document()

    assert LazyHTML.attribute(LazyHTML.query(document, "link[rel=canonical]"), "href") == [
             "https://superx.free/"
           ]

    assert LazyHTML.attribute(LazyHTML.query(document, "meta[name=description]"), "content") == [
             "SuperX is a free, open-source, self-hosted alternative to superx.so for drafting, scheduling, publishing, and measuring posts on X (Twitter)."
           ]

    assert LazyHTML.attribute(LazyHTML.query(document, "meta[property='og:title']"), "content") ==
             [
               "Free, open-source X growth tool · SuperX"
             ]

    assert LazyHTML.attribute(LazyHTML.query(document, "meta[property='og:url']"), "content") == [
             "https://superx.free/"
           ]

    assert LazyHTML.attribute(LazyHTML.query(document, "meta[name='twitter:card']"), "content") ==
             [
               "summary"
             ]

    assert Enum.count(LazyHTML.query(document, "meta[name='theme-color']")) == 2
  end

  test "keeps visible FAQ content and JSON-LD in sync", %{conn: conn} do
    document = conn |> get(~p"/") |> html_response(200) |> LazyHTML.from_document()

    schema =
      document
      |> LazyHTML.query("#landing-structured-data")
      |> LazyHTML.text()
      |> Jason.decode!()

    software = Enum.find(schema["@graph"], &(&1["@type"] == "SoftwareApplication"))
    faq_page = Enum.find(schema["@graph"], &(&1["@type"] == "FAQPage"))

    assert software["name"] == "SuperX"
    assert software["codeRepository"] == "https://github.com/ashishbishnoi18/superx.free"
    assert software["applicationCategory"] == "BusinessApplication"
    assert software["operatingSystem"] == "Linux with Docker"
    assert software["isAccessibleForFree"]
    # Search engines read this instead of the visible copy, so the free path
    # and both hosted prices have to be listed or the two disagree.
    assert Enum.map(software["offers"], & &1["price"]) == ["0", "5", "9"]
    assert Enum.all?(software["offers"], &(&1["priceCurrency"] == "USD"))

    visible_faqs =
      document
      |> LazyHTML.query("#faq-list article")
      |> Enum.map(fn article ->
        {
          article |> LazyHTML.query("h3") |> LazyHTML.text(),
          article |> LazyHTML.query("p") |> LazyHTML.text()
        }
      end)

    structured_faqs =
      Enum.map(faq_page["mainEntity"], fn question ->
        {question["name"], question["acceptedAnswer"]["text"]}
      end)

    assert structured_faqs == visible_faqs
  end

  test "shows executable Docker Compose setup commands", %{conn: conn} do
    document = conn |> get(~p"/") |> html_response(200) |> LazyHTML.from_document()
    commands = document |> LazyHTML.query("#self-host-commands code") |> LazyHTML.text()

    assert commands ==
             "git clone https://github.com/ashishbishnoi18/superx.free.git superx\ncd superx\ncp .env.example .env\ndocker compose up -d --build\ndocker compose exec app /app/bin/migrate"
  end

  describe "where a signed-in user lands" do
    test "a connected but unconfigured account goes to setup", %{conn: conn} do
      %{user: user} = user_fixture()
      {:ok, token} = SuperX.Accounts.create_session(user)

      conn = conn |> init_test_session(%{user_token: token}) |> get(~p"/")

      assert redirected_to(conn) == ~p"/welcome"
    end

    test "a set-up account goes to Home", %{conn: conn} do
      %{user: user} = user_fixture()

      {:ok, user} =
        SuperX.Accounts.update_user(user, %{
          onboarding_completed_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      {:ok, token} = SuperX.Accounts.create_session(user)

      conn = conn |> init_test_session(%{user_token: token}) |> get(~p"/")

      assert redirected_to(conn) == ~p"/home"
    end
  end

  test "serves llms.txt, which is how assistants read what this is" do
    conn = get(build_conn(), "/llms.txt")

    assert conn.status == 200
    body = response(conn, 200)
    assert body =~ "# SuperX"
    assert body =~ "github.com/ashishbishnoi18/superx.free"
  end
end
