defmodule SuperX.Workers.DMSyncTest do
  use SuperX.DataCase, async: false

  import SuperX.Fixtures

  alias SuperX.Workers.DMSync
  alias SuperX.X

  setup do
    previous = Application.get_env(:superx, X, [])

    Application.put_env(
      :superx,
      X,
      Keyword.merge(previous,
        api_base: "https://api.x.com/2",
        dm_enabled: true
      )
    )

    on_exit(fn -> Application.put_env(:superx, X, previous) end)

    user_fixture(x_user_id: "100", scopes: ~w(tweet.read tweet.write dm.read dm.write))
  end

  test "does no work while the feature flag is off" do
    configure_dms(false)

    Req.Test.stub(X, fn _conn ->
      flunk("the disabled worker must not call X")
    end)

    assert :ok = DMSync.perform(%Oban.Job{})
  end

  test "snoozes until X's rate limit resets" do
    reset_at = System.system_time(:second) + 120

    Req.Test.stub(X, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("x-rate-limit-reset", Integer.to_string(reset_at))
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(429, Jason.encode!(%{"title" => "Too Many Requests"}))
    end)

    assert {:snooze, retry_after} = DMSync.perform(%Oban.Job{})
    assert retry_after > 0
    assert retry_after <= 120
  end

  defp configure_dms(enabled) do
    config = Application.get_env(:superx, X, [])
    Application.put_env(:superx, X, Keyword.put(config, :dm_enabled, enabled))
  end
end
