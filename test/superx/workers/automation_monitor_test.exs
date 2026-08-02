defmodule SuperX.Workers.AutomationMonitorTest do
  @moduledoc """
  The monitor reposts and deletes content under the user's name, so the
  decision of *whether* to act gets the coverage: `pending_actions/2` is
  pure and every gate around each action is pinned. The executor gets one
  happy path plus the two failure shapes that decide whether a run loops
  hot against X.
  """

  use SuperX.DataCase, async: false

  import SuperX.Fixtures

  alias SuperX.{Content, Repo}
  alias SuperX.Content.Post
  alias SuperX.Workers.AutomationMonitor

  describe "pending_actions/2 — retweet" do
    test "fires once its delay has elapsed" do
      post = build_post(auto_retweet_hours: 6, published_at: hours_ago(7))

      assert AutomationMonitor.pending_actions(post, now()) == [:retweet]
    end

    test "waits until its delay has elapsed" do
      post = build_post(auto_retweet_hours: 6, published_at: hours_ago(5))

      assert AutomationMonitor.pending_actions(post, now()) == []
    end

    test "does not fire twice" do
      post =
        build_post(
          auto_retweet_hours: 6,
          published_at: hours_ago(7),
          automation_state: %{"retweeted_at" => stamp(hours_ago(1))}
        )

      refute :retweet in AutomationMonitor.pending_actions(post, now())
    end

    test "a terminal failure is not retried" do
      post =
        build_post(
          auto_retweet_hours: 6,
          published_at: hours_ago(7),
          automation_state: %{"failed_retweet" => "X returned 403"}
        )

      refute :retweet in AutomationMonitor.pending_actions(post, now())
    end

    test "does not fire without the trigger configured" do
      post = build_post(published_at: hours_ago(7))

      assert AutomationMonitor.pending_actions(post, now()) == []
    end
  end

  describe "pending_actions/2 — undo retweet" do
    test "fires once the repost is old enough" do
      post =
        build_post(
          auto_retweet_undo_hours: 12,
          published_at: hours_ago(30),
          automation_state: %{"retweeted_at" => stamp(hours_ago(13))}
        )

      assert AutomationMonitor.pending_actions(post, now()) == [:unretweet]
    end

    test "waits until the undo delay has elapsed" do
      post =
        build_post(
          auto_retweet_undo_hours: 12,
          published_at: hours_ago(30),
          automation_state: %{"retweeted_at" => stamp(hours_ago(11))}
        )

      assert AutomationMonitor.pending_actions(post, now()) == []
    end

    test "never fires before the repost exists" do
      post = build_post(auto_retweet_undo_hours: 12, published_at: hours_ago(30))

      refute :unretweet in AutomationMonitor.pending_actions(post, now())
    end

    test "does not fire twice" do
      post =
        build_post(
          auto_retweet_undo_hours: 12,
          published_at: hours_ago(30),
          automation_state: %{
            "retweeted_at" => stamp(hours_ago(20)),
            "unretweeted_at" => stamp(hours_ago(1))
          }
        )

      refute :unretweet in AutomationMonitor.pending_actions(post, now())
    end

    test "ignores an unparseable repost timestamp" do
      post =
        build_post(
          auto_retweet_undo_hours: 12,
          published_at: hours_ago(30),
          automation_state: %{"retweeted_at" => "not-a-date"}
        )

      refute :unretweet in AutomationMonitor.pending_actions(post, now())
    end
  end

  describe "pending_actions/2 — plug" do
    test "fires at the like threshold" do
      post =
        build_post(
          auto_plug_likes: 100,
          auto_plug_text: "link",
          metrics: %{"likes" => 100},
          metrics_updated_at: hours_ago(0)
        )

      assert AutomationMonitor.pending_actions(post, now()) == [:plug]
    end

    test "waits below the like threshold" do
      post =
        build_post(
          auto_plug_likes: 100,
          auto_plug_text: "link",
          metrics: %{"likes" => 99},
          metrics_updated_at: hours_ago(0)
        )

      assert AutomationMonitor.pending_actions(post, now()) == []
    end

    test "waits for metrics to arrive" do
      post =
        build_post(
          auto_plug_likes: 100,
          auto_plug_text: "link",
          metrics: %{},
          metrics_updated_at: hours_ago(0)
        )

      assert AutomationMonitor.pending_actions(post, now()) == []
    end

    test "does not fire twice" do
      post =
        build_post(
          auto_plug_likes: 100,
          auto_plug_text: "link",
          metrics: %{"likes" => 500},
          metrics_updated_at: hours_ago(0),
          automation_state: %{"plugged_at" => stamp(hours_ago(1))}
        )

      refute :plug in AutomationMonitor.pending_actions(post, now())
    end

    test "waits when the like sample is stale" do
      post =
        build_post(
          auto_plug_likes: 100,
          auto_plug_text: "link",
          metrics: %{"likes" => 500},
          metrics_updated_at: hours_ago(2)
        )

      refute :plug in AutomationMonitor.pending_actions(post, now())
    end
  end

  describe "pending_actions/2 — delete" do
    test "fires below the view floor once its delay has elapsed" do
      post =
        build_post(
          auto_delete_min_views: 1000,
          auto_delete_hours: 24,
          published_at: hours_ago(25),
          metrics: %{"views" => 999},
          metrics_updated_at: hours_ago(0)
        )

      assert AutomationMonitor.pending_actions(post, now()) == [:delete]
    end

    test "does not fire at or above the view floor" do
      post =
        build_post(
          auto_delete_min_views: 1000,
          auto_delete_hours: 24,
          published_at: hours_ago(25),
          metrics: %{"views" => 1000},
          metrics_updated_at: hours_ago(0)
        )

      assert AutomationMonitor.pending_actions(post, now()) == []
    end

    test "waits until its delay has elapsed" do
      post =
        build_post(
          auto_delete_min_views: 1000,
          auto_delete_hours: 24,
          published_at: hours_ago(23),
          metrics: %{"views" => 0},
          metrics_updated_at: hours_ago(0)
        )

      assert AutomationMonitor.pending_actions(post, now()) == []
    end

    test "never fires on unknown metrics" do
      post =
        build_post(
          auto_delete_min_views: 1000,
          auto_delete_hours: 24,
          published_at: hours_ago(25),
          metrics: %{},
          metrics_updated_at: nil
        )

      assert AutomationMonitor.pending_actions(post, now()) == []
    end

    test "never fires on metrics written before the schema tracked when" do
      post =
        build_post(
          auto_delete_min_views: 1000,
          auto_delete_hours: 24,
          published_at: hours_ago(25),
          metrics: %{"views" => 0},
          metrics_updated_at: nil
        )

      assert AutomationMonitor.pending_actions(post, now()) == []
    end

    test "never fires on stale metrics" do
      post =
        build_post(
          auto_delete_min_views: 1000,
          auto_delete_hours: 24,
          published_at: hours_ago(25),
          metrics: %{"views" => 0},
          metrics_updated_at: hours_ago(2)
        )

      assert AutomationMonitor.pending_actions(post, now()) == []
    end

    test "never fires on a non-numeric view count" do
      post =
        build_post(
          auto_delete_min_views: 1000,
          auto_delete_hours: 24,
          published_at: hours_ago(25),
          metrics: %{"views" => "0"},
          metrics_updated_at: hours_ago(0)
        )

      assert AutomationMonitor.pending_actions(post, now()) == []
    end

    test "a durable claim freezes every action on the post" do
      post =
        build_post(
          auto_retweet_hours: 1,
          published_at: hours_ago(2),
          automation_state: %{"claimed_retweet_at" => stamp(hours_ago(0))}
        )

      assert AutomationMonitor.pending_actions(post, now()) == []
    end

    test "requires both a floor and a delay" do
      floor_only =
        build_post(
          auto_delete_min_views: 1000,
          published_at: hours_ago(25),
          metrics: %{"views" => 0},
          metrics_updated_at: hours_ago(0)
        )

      delay_only =
        build_post(
          auto_delete_hours: 24,
          published_at: hours_ago(25),
          metrics: %{"views" => 0},
          metrics_updated_at: hours_ago(0)
        )

      assert AutomationMonitor.pending_actions(floor_only, now()) == []
      assert AutomationMonitor.pending_actions(delay_only, now()) == []
    end

    test "does not fire twice" do
      post =
        build_post(
          auto_delete_min_views: 1000,
          auto_delete_hours: 24,
          published_at: hours_ago(25),
          metrics: %{"views" => 0},
          metrics_updated_at: hours_ago(0),
          automation_state: %{"deleted_at" => stamp(hours_ago(1))}
        )

      refute :delete in AutomationMonitor.pending_actions(post, now())
    end
  end

  describe "pending_actions/2 — ordering" do
    test "due actions fire in dependency order" do
      post =
        build_post(
          auto_retweet_undo_hours: 12,
          auto_plug_likes: 100,
          auto_plug_text: "link",
          auto_delete_min_views: 1000,
          auto_delete_hours: 24,
          published_at: hours_ago(40),
          automation_state: %{"retweeted_at" => stamp(hours_ago(20))},
          metrics: %{"likes" => 500, "views" => 10},
          metrics_updated_at: hours_ago(0)
        )

      assert AutomationMonitor.pending_actions(post, now()) == [:unretweet, :plug, :delete]
    end
  end

  describe "perform/1" do
    setup do
      user_fixture()
    end

    test "fires a due retweet and records it", %{user: user, account: account} do
      post = posted_post(user, account, auto_retweet_hours: 1)
      calls = start_supervised!({Agent, fn -> [] end})

      Req.Test.stub(SuperX.X, fn conn ->
        Agent.update(calls, &[conn.request_path | &1])
        json(conn, %{"data" => %{"retweeted" => true}})
      end)

      assert :ok = AutomationMonitor.perform(%Oban.Job{})

      assert %{"retweeted_at" => retweeted_at} = Repo.get!(Post, post.id).automation_state
      assert {:ok, _at, _offset} = DateTime.from_iso8601(retweeted_at)
      assert [path] = Agent.get(calls, & &1)
      assert path =~ "/users/#{account.x_user_id}/retweets"
    end

    test "writes both markers when two actions fire in one run", %{
      user: user,
      account: account
    } do
      post =
        posted_post(user, account,
          auto_retweet_undo_hours: 1,
          auto_plug_likes: 10,
          auto_plug_text: "get the course"
        )

      post
      |> Ecto.Changeset.change(
        automation_state: %{"retweeted_at" => stamp(hours_ago(2))},
        metrics: %{"likes" => 50},
        metrics_updated_at: hours_ago(0)
      )
      |> Repo.update!()

      Req.Test.stub(SuperX.X, fn conn ->
        case conn.method do
          "DELETE" -> json(conn, %{"data" => %{"retweeted" => false}})
          "POST" -> json(conn, %{"data" => %{"id" => "plug-id"}})
        end
      end)

      assert :ok = AutomationMonitor.perform(%Oban.Job{})

      state = Repo.get!(Post, post.id).automation_state
      assert %{"unretweeted_at" => _, "plugged_at" => _} = state
    end

    test "a rate limit stops the rest of the account's run", %{user: user, account: account} do
      _first = posted_post(user, account, auto_retweet_hours: 1)
      _second = posted_post(user, account, auto_retweet_hours: 1)
      attempts = start_supervised!({Agent, fn -> [] end})

      Req.Test.stub(SuperX.X, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        Agent.update(attempts, &[Jason.decode!(body)["tweet_id"] | &1])

        conn
        |> Plug.Conn.put_resp_header(
          "x-rate-limit-reset",
          Integer.to_string(System.system_time(:second) + 900)
        )
        |> Plug.Conn.send_resp(429, ~s({"detail":"too many requests"}))
      end)

      assert :ok = AutomationMonitor.perform(%Oban.Job{})

      # Only one post was ever attempted (Req may retry the 429 itself, so
      # count posts, not requests), and nothing is marked — both posts
      # retry on the next tick.
      assert attempts |> Agent.get(&Enum.uniq/1) |> length() == 1

      assert Repo.all(Post)
             |> Enum.filter(&(&1.status == "posted"))
             |> Enum.all?(&(&1.automation_state == %{}))
    end

    test "a terminal rejection is recorded and never retried", %{user: user, account: account} do
      post = posted_post(user, account, auto_retweet_hours: 1)
      calls = start_supervised!({Agent, fn -> 0 end})

      Req.Test.stub(SuperX.X, fn conn ->
        Agent.update(calls, &(&1 + 1))
        Plug.Conn.send_resp(conn, 403, ~s({"detail":"forbidden"}))
      end)

      assert :ok = AutomationMonitor.perform(%Oban.Job{})
      assert %{"failed_retweet" => "X returned 403"} = Repo.get!(Post, post.id).automation_state

      assert :ok = AutomationMonitor.perform(%Oban.Job{})
      assert Agent.get(calls, & &1) == 1
    end

    test "an account needing reconnect is skipped without calling X", %{
      user: user,
      account: account
    } do
      account |> SuperX.Accounts.XAccount.reauth_changeset("revoked") |> Repo.update!()
      post = posted_post(user, account, auto_retweet_hours: 1)

      Req.Test.stub(SuperX.X, fn conn ->
        json(conn, %{"data" => %{"retweeted" => true}})
      end)

      assert :ok = AutomationMonitor.perform(%Oban.Job{})
      assert Repo.get!(Post, post.id).automation_state == %{}
    end

    test "checks X itself and cancels deletion when the post recovered", %{
      user: user,
      account: account
    } do
      post =
        posted_post(user, account,
          auto_delete_min_views: 1_000,
          auto_delete_hours: 1,
          metrics: %{"views" => 10},
          metrics_updated_at: hours_ago(0)
        )

      calls = start_supervised!({Agent, fn -> [] end})

      Req.Test.stub(SuperX.X, fn conn ->
        Agent.update(calls, &[conn.method | &1])
        assert conn.method == "GET"

        json(conn, %{
          "data" => %{"public_metrics" => %{"impression_count" => 1_500}}
        })
      end)

      assert :ok = AutomationMonitor.perform(%Oban.Job{})
      assert Agent.get(calls, & &1) == ["GET"]

      assert %{"failed_delete" => reason} = Repo.get!(Post, post.id).automation_state
      assert reason =~ "1500 views"
    end

    test "deletes only after X confirms a fresh count below the floor", %{
      user: user,
      account: account
    } do
      post =
        posted_post(user, account,
          auto_delete_min_views: 1_000,
          auto_delete_hours: 1,
          metrics: %{"views" => 10},
          metrics_updated_at: hours_ago(0)
        )

      calls = start_supervised!({Agent, fn -> [] end})

      Req.Test.stub(SuperX.X, fn conn ->
        Agent.update(calls, &[conn.method | &1])

        case conn.method do
          "GET" ->
            json(conn, %{
              "data" => %{"public_metrics" => %{"impression_count" => 100}}
            })

          "DELETE" ->
            json(conn, %{"data" => %{"deleted" => true}})
        end
      end)

      assert :ok = AutomationMonitor.perform(%Oban.Job{})
      assert Enum.sort(Agent.get(calls, & &1)) == ["DELETE", "GET"]
      assert %{"deleted_at" => _timestamp} = Repo.get!(Post, post.id).automation_state
    end
  end

  defp build_post(attrs) do
    defaults = %{
      status: "posted",
      published_at: hours_ago(10),
      x_post_ids: ["x-post-1"],
      automation_state: %{},
      metrics: %{}
    }

    struct(Post, Map.merge(defaults, Map.new(attrs)))
  end

  defp posted_post(user, account, attrs) do
    {:ok, post} =
      Content.create_post(user, account, %{
        segments: [%{"text" => "hello", "media_ids" => []}],
        status: "draft"
      })

    {:ok, post} = Content.mark_published(post, ["x-#{System.unique_integer([:positive])}"])

    post
    |> Ecto.Changeset.change(Map.merge(%{published_at: hours_ago(10)}, Map.new(attrs)))
    |> Repo.update!()
  end

  defp json(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(body))
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
  defp hours_ago(hours), do: DateTime.add(now(), -hours * 3600, :second)
  defp stamp(datetime), do: DateTime.to_iso8601(datetime)
end
