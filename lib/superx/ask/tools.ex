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

  require Logger

  alias SuperX.{Analytics, Articles, Billing, Content, Signals}
  alias SuperX.Content.{Corpus, Writer}
  alias SuperX.Engage

  @doc "Tool definitions in the Anthropic schema."
  def definitions do
    [
      %{
        name: "draft_post",
        description:
          "Write a post in the user's voice about a topic. Returns the draft text and saves it to Ready to Post; does not publish it.",
        input_schema: %{
          type: "object",
          properties: %{
            topic: %{
              type: "string",
              description: "What the post should be about.",
              minLength: 1
            }
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
            text: %{
              type: "string",
              description: "The post text, under 280 characters.",
              minLength: 1,
              maxLength: 280
            }
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
            days: %{
              type: "integer",
              description: "How many days back. Defaults to 30.",
              minimum: 1
            }
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
              description: "One of scheduled, draft, posted, failed. Defaults to scheduled.",
              enum: ~w(scheduled draft posted failed)
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
            query: %{type: "string", minLength: 1},
            min_likes: %{type: "integer", minimum: 0}
          },
          required: ["query"]
        }
      },
      %{
        name: "get_shelf",
        description:
          "Drafts waiting on the Ready to Post shelf. These are written but not yet " <>
            "approved, and are separate from the queue — a question about drafts, the " <>
            "shelf, or what is waiting for review is answered here, not by get_queue.",
        input_schema: %{type: "object", properties: %{}}
      },
      %{
        name: "get_articles",
        description:
          "The user's long-form Articles. These are separate from post drafts, the Ready to Post shelf, and the posting queue.",
        input_schema: %{
          type: "object",
          properties: %{
            status: %{
              type: "string",
              description: "One of draft, ready, published. Defaults to draft.",
              enum: ~w(draft ready published)
            }
          }
        }
      },
      %{
        name: "get_engagements",
        description:
          "Mentions or topic-feed items waiting for a reply. Mentions are highest priority first; feed items are newest first.",
        input_schema: %{
          type: "object",
          properties: %{
            kind: %{
              type: "string",
              description: "One of mention, feed. Omit to read the combined inbox.",
              enum: ~w(mention feed)
            }
          }
        }
      },
      %{
        name: "get_feeds",
        description:
          "The topic feeds the user follows, including whether each is active and whether it has ever synced.",
        input_schema: %{type: "object", properties: %{}}
      },
      %{
        name: "get_leads",
        description:
          "Contacts found by Signals agents, optionally filtered by their relationship stage, best match first.",
        input_schema: %{
          type: "object",
          properties: %{
            status: %{
              type: "string",
              description: "One of new, contacted, replied, won, archived.",
              enum: ~w(new contacted replied won archived)
            }
          }
        }
      }
    ]
  end

  @doc """
  Runs a tool after validating its arguments against the published schema.

  Successful calls return `{:ok, result_string, summary}`. Execution failures
  return `{:error, message}`, while an unknown name is kept distinct so a
  transport can report it as a protocol error.
  """
  def run(name, input, ctx) do
    with {:ok, definition} <- definition(name),
         :ok <- validate_input(input, definition.input_schema) do
      run_safely(name, input, ctx)
    else
      {:error, :unknown_tool} -> {:error, :unknown_tool, "Unknown tool: #{name}"}
      {:error, message} -> {:error, message}
    end
  end

  defp do_run("draft_post", %{"topic" => topic}, ctx) do
    case Writer.generate(ctx.user, ctx.account, topic: topic) do
      {:ok, generation} ->
        refund_nested_generation(ctx)
        text = SuperX.Content.Generation.text(generation)
        {:ok, "Drafted:\n\n#{text}", "Wrote a draft"}

      {:error, :quota_exceeded, _} ->
        {:error, "The user is out of AI credits for this window."}

      {:error, reason} ->
        {:error, "Drafting failed: #{inspect(reason)}"}
    end
  end

  defp do_run("queue_post", %{"text" => text}, ctx) do
    with {:ok, post} <-
           Content.create_post(ctx.user, ctx.account, %{
             segments: [%{"text" => text, "media_ids" => []}],
             status: "draft",
             source: "generated"
           }),
         {:ok, scheduled} <- Content.schedule_post(post) do
      when_str = format_when(scheduled.scheduled_at, ctx.user.timezone)
      {:ok, "Queued for #{when_str}.", "Queued a post for #{when_str}"}
    else
      {:error, :no_slots} ->
        {:error, "The user has no posting times configured, so nothing can be queued."}

      {:error, changeset} ->
        {:error, "Could not queue: #{inspect(changeset.errors)}"}
    end
  end

  defp do_run("get_analytics", input, ctx) do
    days = input["days"] || 30
    s = Analytics.summary(ctx.account, days)

    {:ok,
     """
     Last #{days} days for @#{ctx.account.handle}:
     followers #{s.followers} (#{format_delta(s.followers_change)} in range)
     posts #{s.posts}, impressions #{s.impressions}, engagements #{s.engagements}
     """, "Read #{days}-day analytics"}
  end

  defp do_run("get_queue", input, ctx) do
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

    {:ok, body, "Read the #{status} queue"}
  end

  @shelf_shown 15

  defp do_run("get_shelf", _input, ctx) do
    # shelf_counts/1 already carries the total under "all"; summing the
    # map's values would count it a second time.
    total = Content.shelf_counts(ctx.account)["all"] || 0
    generations = Content.list_shelf(ctx.account, limit: @shelf_shown)

    body =
      if generations == [] do
        "The shelf is empty."
      else
        listed =
          Enum.map_join(generations, "\n\n", fn g ->
            text = g.segments |> Enum.map_join(" / ", &(&1["text"] || "")) |> String.slice(0, 200)

            source =
              if g.source_likes, do: " (from a post with #{g.source_likes} likes)", else: ""

            "#{g.kind}#{source}: #{text}"
          end)

        # The total is stated separately from the sample, or the model
        # reports the page size as the count.
        "#{total} draft(s) on the shelf. Showing #{length(generations)}:\n\n#{listed}"
      end

    {:ok, body, "Read the Ready to Post shelf"}
  end

  defp do_run("get_articles", input, ctx) do
    status = input["status"] || "draft"
    articles = Articles.list_articles(ctx.account, status, limit: 10)

    body =
      if articles == [] do
        "No #{status} Articles."
      else
        Enum.map_join(articles, "\n\n", fn article ->
          title = article.title || "Untitled article"
          excerpt = article.body |> normalise_prose() |> String.slice(0, 200)
          destination = if article.permalink, do: " #{article.permalink}", else: ""

          "#{title} (#{article.word_count} words): #{excerpt}#{destination}"
        end)
      end

    {:ok, body, "Read #{status} Articles"}
  end

  defp do_run("search_inspiration", %{"query" => query} = input, _ctx) do
    posts = Corpus.search(query: query, min_likes: input["min_likes"] || 500, limit: 8)

    body =
      if posts == [] do
        "Nothing in the library matched. The corpus may not be populated yet."
      else
        Enum.map_join(posts, "\n\n", fn p ->
          "@#{p.author_handle} (#{p.likes} likes): #{p.text}"
        end)
      end

    {:ok, body, "Searched the library for #{inspect(query)}"}
  end

  defp do_run("get_engagements", input, ctx) do
    kind = input["kind"]
    items = Engage.list_engagements(ctx.account, kind: kind, limit: 10)

    body =
      if items == [] do
        if kind, do: "No #{kind} items waiting.", else: "Nothing waiting."
      else
        Enum.map_join(items, "\n\n", fn e ->
          "[#{e.priority}] @#{e.author_handle} (#{e.author_followers} followers): #{e.text}"
        end)
      end

    {:ok, body, "Read the engagement inbox"}
  end

  defp do_run("get_feeds", _input, ctx) do
    feeds = Engage.list_feeds(ctx.account)

    body =
      if feeds == [] do
        "No topic feeds configured."
      else
        Enum.map_join(feeds, "\n", fn feed ->
          state = if feed.enabled, do: "active", else: "paused"
          synced = if feed.last_synced_at, do: "synced", else: "not fetched yet"
          "#{feed.name}: #{feed.query} (#{state}, #{feed.ranking}, #{synced})"
        end)
      end

    {:ok, body, "Read the topic feeds"}
  end

  defp do_run("get_leads", input, ctx) do
    status = input["status"]
    leads = Signals.list_leads(ctx.account, status: status, limit: 10)

    body =
      if leads == [] do
        if status, do: "No #{status} contacts.", else: "No contacts yet."
      else
        Enum.map_join(leads, "\n", fn l ->
          note = if l.notes, do: " Notes: #{normalise_prose(l.notes)}", else: ""

          "@#{l.handle} [#{l.status}] (#{l.followers_count} followers, score #{l.score}): #{l.reason || l.bio}#{note}"
        end)
      end

    {:ok, body, "Read the contact list"}
  end

  defp do_run(name, _input, _ctx), do: {:error, "Unknown tool: #{name}"}

  defp definition(name) do
    case Enum.find(definitions(), &(&1.name == name)) do
      nil -> {:error, :unknown_tool}
      definition -> {:ok, definition}
    end
  end

  defp validate_input(input, _schema) when not is_map(input),
    do: {:error, "Invalid arguments: expected an object."}

  defp validate_input(input, schema) do
    with :ok <- validate_required(input, Map.get(schema, :required, [])),
         :ok <- validate_properties(input, Map.get(schema, :properties, %{})) do
      :ok
    end
  end

  defp validate_required(input, required) do
    case Enum.find(required, &(not Map.has_key?(input, &1))) do
      nil -> :ok
      name -> {:error, "Invalid arguments: #{name} is required."}
    end
  end

  defp validate_properties(input, properties) do
    Enum.reduce_while(properties, :ok, fn {name, schema}, :ok ->
      key = to_string(name)

      case Map.fetch(input, key) do
        :error -> {:cont, :ok}
        {:ok, value} -> validate_property(key, value, schema)
      end
    end)
  end

  defp validate_property(name, value, schema) do
    case validate_type(value, schema.type) do
      :ok -> validate_constraints(name, value, schema)
      {:error, type} -> {:halt, {:error, "Invalid arguments: #{name} must be #{type}."}}
    end
  end

  defp validate_type(value, "string") when is_binary(value), do: :ok
  defp validate_type(value, "integer") when is_integer(value), do: :ok
  defp validate_type(value, "object") when is_map(value), do: :ok
  defp validate_type(_value, "string"), do: {:error, "a string"}
  defp validate_type(_value, "integer"), do: {:error, "an integer"}
  defp validate_type(_value, "object"), do: {:error, "an object"}
  defp validate_type(_value, _type), do: :ok

  defp validate_constraints(name, value, schema) do
    cond do
      schema[:enum] && value not in schema.enum ->
        {:halt,
         {:error, "Invalid arguments: #{name} must be one of #{Enum.join(schema.enum, ", ")}."}}

      schema[:minimum] && value < schema.minimum ->
        {:halt, {:error, "Invalid arguments: #{name} must be at least #{schema.minimum}."}}

      schema[:minLength] && String.length(value) < schema.minLength ->
        {:halt,
         {:error, "Invalid arguments: #{name} must be at least #{schema.minLength} character."}}

      schema[:maxLength] && String.length(value) > schema.maxLength ->
        {:halt,
         {:error, "Invalid arguments: #{name} must be at most #{schema.maxLength} characters."}}

      true ->
        {:cont, :ok}
    end
  end

  defp run_safely(name, input, ctx) do
    do_run(name, input, ctx)
  rescue
    error ->
      Logger.warning("Ask tool #{name} crashed: #{inspect(error)}")
      {:error, "That tool failed."}
  end

  # A Writer generation normally costs one credit so direct MCP use is
  # metered. Inside Ask, the advertised three-credit turn already includes
  # every tool it chooses; refund the nested claim so that promise remains
  # true regardless of the chosen tool path.
  defp refund_nested_generation(%{billing: :ask, user: user}) do
    Billing.refund_credits(user, Writer.credit_cost(), ref_type: "ask")
  end

  defp refund_nested_generation(_ctx), do: :ok

  defp normalise_prose(nil), do: ""

  defp normalise_prose(text) do
    text |> String.replace(~r/\s+/u, " ") |> String.trim()
  end

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
