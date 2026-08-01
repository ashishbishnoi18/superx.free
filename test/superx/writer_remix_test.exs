defmodule SuperX.Content.WriterRemixTest do
  @moduledoc """
  A remix is still paid generation. The important boundary is that it uses
  the proven rewrite path, claims once for usable work, and refunds every
  failed provider call without filing the user's post in the shared corpus.
  """

  use SuperX.DataCase, async: false

  import SuperX.Fixtures

  alias SuperX.Content
  alias SuperX.Content.Writer
  alias SuperX.{Billing, Repo}

  setup do
    previous = Application.get_env(:superx, SuperX.AI, [])

    Application.put_env(
      :superx,
      SuperX.AI,
      Keyword.merge(previous, api_key: "test-key", writer_model: "test-model")
    )

    on_exit(fn -> Application.put_env(:superx, SuperX.AI, previous) end)

    %{user: user, account: account} = user_fixture()
    {:ok, voice} = Content.get_or_create_voice_profile(account)
    {:ok, _voice} = Content.update_voice_profile(voice, %{topics: "durable software"})

    {:ok, post} =
      Content.create_post(user, account, %{
        status: "draft",
        segments: [%{"text" => "A migration is a promise about every row that already exists."}]
      })

    {:ok, post} = Content.mark_published(post, ["published-source"])

    %{user: user, account: account, post: post}
  end

  defp stub(fun), do: Req.Test.stub(SuperX.AI, fun)

  defp read_body(conn) do
    {:ok, raw, conn} = Plug.Conn.read_body(conn)
    {Jason.decode!(raw), conn}
  end

  defp reply(text) do
    %{
      "content" => [
        %{
          "type" => "tool_use",
          "id" => "post_1",
          "name" => "respond",
          "input" => %{"segments" => [text]}
        }
      ]
    }
  end

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end

  test "writes through the structural rewrite and claims one credit", %{
    user: user,
    account: account,
    post: post
  } do
    stub(fn conn ->
      {request, conn} = read_body(conn)
      prompt = request["messages"] |> List.first() |> Map.fetch!("content")

      assert prompt =~ "A migration is a promise about every row"
      assert prompt =~ "durable software"

      json(conn, 200, reply("Quiet systems earn trust before anyone notices their speed."))
    end)

    before = Billing.credit_balance(user)

    assert {:ok, generation} = Writer.remix(user, account, post)
    assert Billing.credit_balance(user) == before - Writer.credit_cost()
    assert generation.source_corpus_post_id == nil
    assert generation.source_likes == nil
    assert generation.kind == "for_you"
  end

  test "refunds the claim when the provider fails", %{user: user, account: account, post: post} do
    stub(fn conn -> json(conn, 503, %{"error" => "unavailable"}) end)
    before = Billing.credit_balance(user)

    assert {:error, {:http_error, 503, _body}} = Writer.remix(user, account, post)
    assert Billing.credit_balance(user) == before

    assert Enum.map(Billing.list_credit_entries(user), & &1.delta) == [
             Writer.credit_cost(),
             -Writer.credit_cost()
           ]
  end

  test "rejects an unpublished source before spending", %{user: user, account: account} do
    {:ok, draft} =
      Content.create_post(user, account, %{
        status: "draft",
        segments: [%{"text" => "not public yet"}]
      })

    before = Billing.credit_balance(user)

    assert {:error, :not_published} = Writer.remix(user, account, draft)
    assert Billing.credit_balance(user) == before
    assert Repo.aggregate(SuperX.Billing.CreditEntry, :count) == 0
  end
end
