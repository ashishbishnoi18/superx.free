defmodule SuperX.Content.VoiceTest do
  use SuperX.DataCase, async: false

  import SuperX.Fixtures

  alias SuperX.{AI, TwitterAPI, X}
  alias SuperX.Content.Voice

  setup do
    previous_ai = Application.get_env(:superx, AI, [])
    previous_twitter = Application.get_env(:superx, TwitterAPI, [])

    Application.put_env(
      :superx,
      AI,
      Keyword.merge(previous_ai, api_key: "test-key", base_url: "https://api.anthropic.test")
    )

    Application.put_env(
      :superx,
      TwitterAPI,
      Keyword.put(previous_twitter, :api_key, nil)
    )

    on_exit(fn ->
      Application.put_env(:superx, AI, previous_ai)
      Application.put_env(:superx, TwitterAPI, previous_twitter)
    end)

    user_fixture()
  end

  test "does not turn a failed post read into a successful bio-only derivation", %{
    account: account
  } do
    Req.Test.stub(X, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(400, Jason.encode!(%{"error" => "read failed"}))
    end)

    Req.Test.stub(AI, fn _conn ->
      flunk("the model must not run after the post read failed")
    end)

    assert {:error, {:post_fetch_failed, {:http_error, 400, %{"error" => "read failed"}}}} =
             Voice.derive(account)
  end
end
