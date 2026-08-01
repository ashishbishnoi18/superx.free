defmodule SuperX.Articles.WriterTest do
  @moduledoc """
  Long-form calls can consume far more tokens than a post, so the billing
  boundary is the important contract: one claim for usable prose and a
  full refund whenever the provider fails.
  """

  use SuperX.DataCase, async: false

  import SuperX.Fixtures

  alias SuperX.Articles.Writer
  alias SuperX.{Billing, Content}

  setup do
    previous = Application.get_env(:superx, SuperX.AI, [])

    Application.put_env(
      :superx,
      SuperX.AI,
      Keyword.merge(previous, api_key: "test-key", writer_model: "test-model")
    )

    on_exit(fn -> Application.put_env(:superx, SuperX.AI, previous) end)

    user_fixture()
  end

  defp stub(fun), do: Req.Test.stub(SuperX.AI, fun)

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end

  defp read_body(conn) do
    {:ok, raw, conn} = Plug.Conn.read_body(conn)
    {Jason.decode!(raw), conn}
  end

  defp article_reply(title, body) do
    %{
      "content" => [
        %{
          "type" => "tool_use",
          "id" => "article_1",
          "name" => "respond",
          "input" => %{"title" => title, "body" => body}
        }
      ]
    }
  end

  test "a usable draft costs exactly one composition credit", %{user: user, account: account} do
    {:ok, voice} = Content.get_or_create_voice_profile(account)

    {:ok, _voice} =
      Content.update_voice_profile(voice, %{about: "I write from measured experience."})

    stub(fn conn ->
      {request, conn} = read_body(conn)
      assert request["system"] =~ "I write from measured experience."

      json(conn, 200, article_reply("The useful title", "The complete body."))
    end)

    before = Billing.credit_balance(user)

    assert {:ok, result} =
             Writer.compose(user, account, :draft, %{
               title: "",
               body: "",
               instruction: "Explain why calm interfaces help people think."
             })

    assert result == %{title: "The useful title", body: "The complete body."}
    assert Billing.credit_balance(user) == before - Writer.credit_cost()

    assert [entry] = Billing.list_credit_entries(user)
    assert entry.delta == -Writer.credit_cost()
    assert entry.reason == "generation"
    assert entry.ref_type == "article"
  end

  test "provider failure refunds the full claim", %{user: user, account: account} do
    stub(fn conn -> json(conn, 503, %{"error" => "unavailable"}) end)
    before = Billing.credit_balance(user)

    assert {:error, {:http_error, 503, _body}} =
             Writer.compose(user, account, :draft, %{
               instruction: "Write about durable software."
             })

    assert Billing.credit_balance(user) == before

    entries = Billing.list_credit_entries(user)
    assert Enum.map(entries, & &1.delta) == [Writer.credit_cost(), -Writer.credit_cost()]
    assert Enum.map(entries, & &1.reason) == ["refund", "generation"]
  end

  test "invalid work is rejected before claiming a credit", %{user: user, account: account} do
    before = Billing.credit_balance(user)

    assert {:error, :missing_brief} = Writer.compose(user, account, :draft, %{})
    assert {:error, :empty_article} = Writer.compose(user, account, :extend, %{body: ""})

    assert Billing.credit_balance(user) == before
    assert Billing.list_credit_entries(user) == []
  end
end
