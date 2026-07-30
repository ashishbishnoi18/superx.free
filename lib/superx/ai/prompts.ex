defmodule SuperX.AI.Prompts do
  @moduledoc """
  Prompt construction for voice derivation and post writing.

  Kept in one module so prompt changes are reviewable in isolation —
  they affect output quality more than any other code here.
  """

  alias SuperX.Accounts.XAccount
  alias SuperX.Content.{CorpusPost, VoiceProfile}

  @doc "JSON schema for a derived voice profile."
  def voice_schema do
    %{
      type: "object",
      properties: %{
        about: %{
          type: "string",
          description:
            "A first-person paragraph describing who this person is and what they post about, written as if by them."
        },
        topics: %{
          type: "string",
          description: "Four to eight comma-separated subject areas they post about."
        },
        questions: %{
          type: "array",
          items: %{type: "string"},
          description:
            "Three to five questions this person is uniquely positioned to answer, used later as writing prompts."
        },
        style_notes: %{
          type: "string",
          description:
            "Concrete observations about their mechanics: sentence length, capitalisation, punctuation, emoji and hashtag use, whether they use line breaks, how they open and close posts."
        }
      },
      required: ["about", "topics", "questions", "style_notes"]
    }
  end

  @doc """
  Prompt that derives a voice profile from an account's own posts.
  """
  def derive_voice(%XAccount{} = account, posts) do
    samples =
      posts
      |> Enum.take(60)
      |> Enum.with_index(1)
      |> Enum.map_join("\n\n", fn {post, i} ->
        text = post["text"] || post[:text] || ""
        "#{i}. #{text}"
      end)

    """
    Analyse this X (Twitter) account and describe how its author writes.

    <account>
    Name: #{account.display_name || account.handle}
    Handle: @#{account.handle}
    Bio: #{account.description || "(none)"}
    Followers: #{account.followers_count}
    </account>

    <their_posts>
    #{if samples == "", do: "(this account has no posts yet)", else: samples}
    </their_posts>

    Describe the author as they actually write, not as they might wish to.
    Be specific and concrete — "short declarative sentences, no emoji,
    lowercase openings, often ends on a question" is useful; "engaging and
    authentic" is not.

    If there are few or no posts to go on, infer conservatively from the bio
    and say less rather than inventing a personality.
    """
  end

  @doc "JSON schema for a written post."
  def post_schema do
    %{
      type: "object",
      properties: %{
        segments: %{
          type: "array",
          items: %{type: "string"},
          description:
            "The post text. One element for a single post; several for a thread, each under 280 characters."
        },
        reasoning: %{
          type: "string",
          description: "One sentence on why this structure suits the topic."
        }
      },
      required: ["segments"]
    }
  end

  @doc """
  The system prompt for all post writing. Everything that keeps output
  from reading as AI lives here.
  """
  def writer_system(%VoiceProfile{} = voice, %XAccount{} = account) do
    """
    You write X (Twitter) posts as #{account.display_name || "@" <> account.handle}.
    You are not an assistant writing on their behalf — you are them, writing.

    <voice>
    #{voice.about || "No voice profile has been built yet; write plainly and specifically."}
    </voice>

    <topics>
    #{voice.topics || "(not specified)"}
    </topics>

    #{style_block(voice)}

    Rules:
    - Match the mechanics above exactly: capitalisation, punctuation, line
      breaks, and whether they use emoji or hashtags. If they never use
      hashtags, you never use hashtags.
    - Write one concrete idea. Specifics beat summary. A real number, a real
      moment, or a real opinion beats a general observation every time.
    - No engagement bait. Do not open with "Unpopular opinion:", "Hot take:",
      "Let me be honest", or "Here's the thing". Do not end by asking people
      to like, repost, or comment.
    - No em dashes. No "it's not X, it's Y" constructions. No rule of three
      just for rhythm.
    - Never mention that anything was AI-written, and never reference the
      post you were shown as inspiration.
    - Stay under 280 characters per segment. Prefer a single post unless the
      idea genuinely needs several.

    #{rules_block(voice)}
    """
  end

  defp style_block(%VoiceProfile{style_notes: notes}) when is_binary(notes) and notes != "" do
    """
    <mechanics>
    #{notes}
    </mechanics>
    """
  end

  defp style_block(_), do: ""

  defp rules_block(%VoiceProfile{rules: rules}) when is_binary(rules) and rules != "" do
    """
    The author has given these instructions directly. They override
    everything above:

    <author_rules>
    #{rules}
    </author_rules>
    """
  end

  defp rules_block(_), do: ""

  @doc """
  Prompt that rewrites a high-performing post's *structure* in the user's
  voice, on one of the user's own topics.

  The distinction matters: copying the topic produces posts the user has
  no standing to make, while copying the shape produces something that
  reads as theirs but is built on a form that already worked.
  """
  def rewrite_from_corpus(%CorpusPost{} = source, topic, examples) do
    """
    Here is a post that performed unusually well:

    <reference_post>
    #{source.text}
    </reference_post>

    It earned #{source.likes} likes and #{source.reposts} reposts.

    Study what makes it work structurally — how it opens, how it builds,
    how long the lines are, where the turn is, how it lands. Ignore its
    subject entirely.

    Now write a new post using that same structure, about:

    <topic>
    #{topic}
    </topic>

    #{examples_block(examples)}

    The result must be about the topic above, in the author's own voice, and
    must not reference the post you were shown. Someone who read both should
    see no resemblance in subject — only in shape.
    """
  end

  @doc "Prompt for writing on a topic with no corpus reference."
  def write_from_topic(topic, examples) do
    """
    Write an X post about:

    <topic>
    #{topic}
    </topic>

    #{examples_block(examples)}

    Make one specific point. Do not summarise the topic — say something
    about it that only this author would say.
    """
  end

  defp examples_block([]), do: ""

  defp examples_block(examples) do
    formatted = Enum.map_join(examples, "\n\n---\n\n", & &1)

    """
    For reference, here is how this author has written before. Match this
    register, not the reference post's:

    <author_examples>
    #{formatted}
    </author_examples>
    """
  end

  @doc "Schema for classifying a corpus post into topics."
  def topic_schema do
    %{
      type: "object",
      properties: %{
        topics: %{
          type: "array",
          items: %{type: "string"},
          description: "Two to four lowercase topic tags, e.g. \"startups\", \"ai\", \"fitness\"."
        },
        quality: %{
          type: "integer",
          description:
            "1-10: how useful this is as a structural template. Engagement bait, giveaways, and pure self-promotion score low."
        }
      },
      required: ["topics", "quality"]
    }
  end

  @doc "Prompt for tagging and quality-scoring a corpus post at ingest."
  def classify_corpus_post(text) do
    """
    Classify this X post for a library of structural writing templates.

    <post>
    #{text}
    </post>

    Score quality by how well the post's *form* would transfer to another
    subject. A well-built argument or a sharp observation scores high.
    Giveaways, follow-for-follow, engagement bait, and posts that only make
    sense with their media score low.
    """
  end
end
