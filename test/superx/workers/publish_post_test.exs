defmodule SuperX.Workers.PublishPostTest do
  use SuperX.DataCase, async: false

  import SuperX.Fixtures

  alias SuperX.{Content, Media, Repo}
  alias SuperX.Content.Post
  alias SuperX.Workers.PublishPost

  setup do
    previous = Application.get_env(:superx, Media, [])
    path = Path.join(System.tmp_dir!(), "superx-publisher-#{System.unique_integer([:positive])}")
    Application.put_env(:superx, Media, path: path)

    on_exit(fn ->
      Application.put_env(:superx, Media, previous)
      File.rm_rf!(path)
    end)

    user_fixture()
  end

  test "never creates a text-only post when X rejects its media", %{user: user, account: account} do
    media_id = stored_png()
    post = scheduled_post(user, account, media_id)
    calls = start_supervised!({Agent, fn -> [] end})

    Req.Test.stub(SuperX.X, fn conn ->
      Agent.update(calls, &[conn.request_path | &1])
      Plug.Conn.send_resp(conn, 400, ~s({"detail":"bad media"}))
    end)

    assert :ok = PublishPost.perform(%Oban.Job{args: %{"post_id" => post.id}, attempt: 5})

    failed = Repo.get!(Post, post.id)
    assert failed.status == "failed"
    assert failed.x_post_ids == []
    assert failed.error =~ "X returned 400"
    refute "/2/tweets" in Agent.get(calls, & &1)
  end

  test "attaches the fresh X media id when it creates the post", %{user: user, account: account} do
    media_id = stored_png()
    post = scheduled_post(user, account, media_id)
    request = start_supervised!({Agent, fn -> 0 end})

    Req.Test.stub(SuperX.X, fn conn ->
      number = Agent.get_and_update(request, &{&1 + 1, &1 + 1})

      case number do
        1 ->
          json(conn, 200, %{"data" => %{"id" => "fresh-media-id"}})

        2 ->
          Plug.Conn.send_resp(conn, 204, "")

        3 ->
          json(conn, 200, %{"data" => %{"id" => "fresh-media-id"}})

        4 ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          assert Jason.decode!(body)["media"] == %{"media_ids" => ["fresh-media-id"]}
          json(conn, 201, %{"data" => %{"id" => "x-post-id"}})
      end
    end)

    assert :ok = PublishPost.perform(%Oban.Job{args: %{"post_id" => post.id}, attempt: 1})

    published = Repo.get!(Post, post.id)
    assert published.status == "posted"
    assert published.x_post_ids == ["x-post-id"]
    assert Agent.get(request, & &1) == 4
  end

  defp scheduled_post(user, account, media_id) do
    {:ok, post} =
      Content.create_post(user, account, %{
        segments: [%{"text" => "with media", "media_ids" => [media_id]}],
        status: "draft"
      })

    {:ok, post} = Content.schedule_post(post)
    post
  end

  defp stored_png do
    temporary =
      Path.join(System.tmp_dir!(), "superx-publish-media-#{System.unique_integer([:positive])}")

    File.write!(temporary, <<0x89, "PNG\r\n", 0x1A, "\n", 0, 0, 0, 0>>)
    on_exit(fn -> File.rm(temporary) end)
    {:ok, media_id} = Media.store_upload(%{path: temporary})
    media_id
  end

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end
end
