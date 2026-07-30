defmodule SuperX.Ask.Tools do
  @moduledoc """
  What Ask is allowed to do on the user's behalf.

  Two rules shape this list:

    * **Nothing publishes.** Tools can draft and queue, never post. A chat
      turn that puts something on X irreversibly is a bad trade for the
      convenience, and the queue is one click from the user anyway.
    * **Reads are scoped to the acting account.** Every tool takes the
      account from the session rather than an argument, so the model can't
      be talked into reading someone else's data.
  """

  alias SuperX.{Analytics, Content, Signals}
  alias SuperX.Content.{Corpus, Writer}
  alias SuperX.Engage

  @doc "Tool definitions in the Anthropic schema."
  def definitions do
    [
      %{
        name: "draft_post",
        description:
          "Write a post in the user's voice about a topic. Returns the draft text; does not save or publish it.",
        input_schema: %{
          type: "object",
          properties: %{
            topic: %{type: "string", description: "What the post should be about."}
          },
          required: ["topic"]
        }
      },
      %{
        name: "queue_post",
        description:
          "Save a post and schedule it into the next open slot. Use the exact text the user approved. Never invent text the user has not seen.",
        input_schema: %{
          type: "object",
          properties: %{
            text: %{type: "string", description: "The post text, under 280 characters."}
          },
          required: ["text"]
        }
      },
      %{
        name: "get_analytics",
        description: "Follower, post, impression and engagement figures for a recent window.",
        input_schema: %{
          type: "object",
          properties: %{
            days: %{type: "integer", description: "How many days back. Defaults to 30."}
          }
        }
      },
      %{
        name: "get_queue",
        description: "What is currently scheduled, drafted, published or failed.",
        input_schema: %{
          type: "object",
          properties: %{
            status: %{
              type: "string",
              description: "One of scheduled, draft, posted, failed. Defaults to scheduled."
            }
          }
        }
      },
      %{
        name: "search_inspiration",
        description:
          "Search the library of high-performing posts. Use this to ground advice in what actually worked rather than guessing.",
        input_schema: %{
          type: "object",
          properties: %{
            query: %{type: "string"},
            min_likes: %{type: "integer"}
          },
          required: ["query"]
        }
      },
      %{
        name: "get_engagements",
        description: "Mentions and feed items waiting for a reply, highest priority first.",
        input_schema: %{type: "object", properties: %{}}
      },
      %{
        name: "get_leads",
        description: "People the Signals agents found, best match first.",
        input_schema: %{type: "object", properties: %{}}
      }
    ]
  end

  @doc """
  Runs a tool. Returns `{result_string, summary}` — the string goes back to
  the model, the summary is what the UI shows the user so they can see
  what was actually done rather than taking the prose on trust.
  """
  def run(name, input, ctx)

  def run("draft_post", %{"topic" => topic}, ctx) do
    case Writer.generate(ctx.user, ctx.account, topic: topic) do
      {:ok, generation} ->
        text = SuperX.Content.Generation.text(generation)
        {"Drafted:\n\n#{text}", "Wrote a draft"}

      {:error, :quota_exceeded, _} ->
        {"The user is out of AI credits for this window.", nil}

      {:error, reason} ->
        {"Drafting failed: #{inspect(reason)}", nil}
    end
  end

  def run("queue_post", %{"text" => text}, ctx) do
    with {:ok, post} <-
           Content.create_post(ctx.user, ctx.account, %{
             segments: [%{"text" => text, "media_ids" => []}],
             status: "draft",
             source: "generated"
           }),
         {:ok, scheduled} <- Content.schedule_post(post) do
      when_str = format_when(scheduled.scheduled_at, ctx.user.timezone)
      {"Queued for #{when_str}.", "Queued a post for #{when_str}"}
    else
      {:error, :no_slots} ->
        {"The user has no posting times configured, so nothing can be queued.", nil}

      {:error, changeset} ->
        {"Could not queue: #{inspect(changeset.errors)}", nil}
    end
  end

  def run("get_analytics", input, ctx) do
    days = input["days"] || 30
    s = Analytics.summary(ctx.account, days)

    {"""
     Last #{days} days for @#{ctx.account.handle}:
     followers #{s.followers} (#{format_delta(s.followers_change)} in range)
     posts #{s.posts}, impressions #{s.impressions}, engagements #{s.engagements}
     """, "Read #{days}-day analytics"}
  end

  def run("get_queue", input, ctx) do
    status = input["status"] || "scheduled"
    posts = Content.list_posts(ctx.account, status, limit: 15)

    body =
      if posts == [] do
        "Nothing with status #{status}."
      else
        Enum.map_join(posts, "\n\n", fn p ->
          "#{format_when(p.scheduled_at || p.published_at, ctx.user.timezone)}: #{Content.Post.preview_text(p)}"
        end)
      end

    {body, "Read the #{status} queue"}
  end

  def run("search_inspiration", %{"query" => query} = input, _ctx) do
    posts = Corpus.search(query: query, min_likes: input["min_likes"] || 500, limit: 8)

    body =
      if posts == [] do
        "Nothing in the library matched. The corpus may not be populated yet."
      else
        Enum.map_join(posts, "\n\n", fn p ->
          "@#{p.author_handle} (#{p.likes} likes): #{p.text}"
        end)
      end

    {body, "Searched the library for #{inspect(query)}"}
  end

  def run("get_engagements", _input, ctx) do
    items = Engage.list_engagements(ctx.account, limit: 10)

    body =
      if items == [] do
        "Nothing waiting."
      else
        Enum.map_join(items, "\n\n", fn e ->
          "[#{e.priority}] @#{e.author_handle} (#{e.author_followers} followers): #{e.text}"
        end)
      end

    {body, "Read the engagement inbox"}
  end

  def run("get_leads", _input, ctx) do
    leads = Signals.list_leads(ctx.account, limit: 10)

    body =
      if leads == [] do
        "No leads yet."
      else
        Enum.map_join(leads, "\n", fn l ->
          "@#{l.handle} (#{l.followers_count} followers, score #{l.score}): #{l.reason || l.bio}"
        end)
      end

    {body, "Read the contact list"}
  end

  def run(name, _input, _ctx), do: {"Unknown tool: #{name}", nil}

  defp format_delta(n) when n > 0, do: "+#{n}"
  defp format_delta(n), do: to_string(n)

  defp format_when(nil, _tz), do: "an unscheduled time"

  defp format_when(datetime, timezone) do
    case DateTime.shift_zone(datetime, timezone, Tz.TimeZoneDatabase) do
      {:ok, local} -> Calendar.strftime(local, "%a %-d %b at %H:%M")
      _ -> Calendar.strftime(datetime, "%a %-d %b at %H:%M UTC")
    end
  end
end
