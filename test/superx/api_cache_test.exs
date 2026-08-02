defmodule SuperX.ApiCacheTest do
  @moduledoc """
  The provider bills per record, so what matters here is that an
  identical call is never bought twice, and that nothing is served stale
  for longer than the endpoint can stand.
  """

  use SuperX.DataCase, async: true

  alias SuperX.ApiCache
  alias SuperX.ApiCache.ApiResponse
  alias SuperX.Repo

  defp body(n) do
    %{"tweets" => Enum.map(1..n, &%{"id" => to_string(&1)})}
  end

  describe "fetch/3" do
    test "buys once and serves the rest from storage" do
      calls = :counters.new(1, [])

      run = fn ->
        ApiCache.fetch("/twitter/tweet/advanced_search", %{"query" => "ai"}, fn ->
          :counters.add(calls, 1, 1)
          {:ok, body(20)}
        end)
      end

      assert {:ok, first} = run.()
      assert {:ok, second} = run.()
      assert {:ok, third} = run.()

      assert first == second and second == third
      assert :counters.get(calls, 1) == 1
    end

    test "different params are different calls" do
      calls = :counters.new(1, [])

      run = fn query ->
        ApiCache.fetch("/twitter/tweet/advanced_search", %{"query" => query}, fn ->
          :counters.add(calls, 1, 1)
          {:ok, body(5)}
        end)
      end

      run.("ai")
      run.("design")

      assert :counters.get(calls, 1) == 2
    end

    test "key does not depend on map ordering" do
      calls = :counters.new(1, [])

      run = fn params ->
        ApiCache.fetch("/twitter/tweet/replies", params, fn ->
          :counters.add(calls, 1, 1)
          {:ok, body(1)}
        end)
      end

      run.(%{"tweetId" => "1", "cursor" => "abc"})
      run.(%{"cursor" => "abc", "tweetId" => "1"})

      assert :counters.get(calls, 1) == 1
    end

    test "a cursor makes it a distinct call, so paging is cached per page" do
      calls = :counters.new(1, [])

      run = fn params ->
        ApiCache.fetch("/twitter/tweet/advanced_search", params, fn ->
          :counters.add(calls, 1, 1)
          {:ok, body(20)}
        end)
      end

      run.(%{"query" => "ai"})
      run.(%{"query" => "ai", "cursor" => "page2"})
      run.(%{"query" => "ai", "cursor" => "page2"})

      assert :counters.get(calls, 1) == 2
    end

    test "errors are never cached — a blip would otherwise last the whole window" do
      calls = :counters.new(1, [])

      run = fn result ->
        ApiCache.fetch("/twitter/user/mentions", %{"userName" => "x"}, fn ->
          :counters.add(calls, 1, 1)
          result
        end)
      end

      assert {:error, :rate_limited} = run.({:error, :rate_limited})
      assert {:error, :rate_limited} = run.({:error, :rate_limited})
      assert {:ok, _} = run.({:ok, body(3)})

      assert :counters.get(calls, 1) == 3
    end

    test "an answer older than the endpoint's window is refetched" do
      calls = :counters.new(1, [])

      run = fn ->
        ApiCache.fetch("/twitter/user/mentions", %{"userName" => "x"}, fn ->
          :counters.add(calls, 1, 1)
          {:ok, body(2)}
        end)
      end

      run.()
      stale_at = DateTime.add(DateTime.utc_now(), -301, :second)
      Repo.update_all(ApiResponse, set: [fetched_at: stale_at])
      run.()

      assert :counters.get(calls, 1) == 2
    end
  end

  describe "spend_report/1" do
    test "reports what was bought and what the cache saved" do
      fetch = fn ->
        ApiCache.fetch("/twitter/tweet/advanced_search", %{"query" => "ai"}, fn ->
          {:ok, body(20)}
        end)
      end

      fetch.()
      fetch.()
      fetch.()

      assert [row] = ApiCache.spend_report()
      assert row.path == "/twitter/tweet/advanced_search"
      assert row.calls == 1
      assert row.bought == 20
      # Two reads answered without paying: 40 records not bought.
      assert row.served_from_cache == 2
      assert row.saved == 40
    end
  end
end
