defmodule SuperXWeb.PageController do
  use SuperXWeb, :controller

  plug :redirect_if_authenticated when action in [:home]

  @features [
    %{
      title: "Draft in your voice",
      body:
        "Connect your X account and, with an LLM key, turn your own posts and topic notes into editable posts or threads."
    },
    %{
      title: "Review, schedule, and publish",
      body:
        "Write a post yourself or approve an AI draft, choose recurring weekly time slots, and let the queue publish with visible failure states."
    },
    %{
      title: "Work through replies and leads",
      body:
        "With a public-data source, collect mentions and topic feeds in one inbox. An LLM key adds reply drafts and lead scoring."
    },
    %{
      title: "See what happened",
      body:
        "Keep follower and post snapshots, review trends and posting streaks, and file people found by Signals into private contact lists."
    }
  ]

  @faqs [
    %{
      question: "How much does SuperX cost?",
      answer:
        "The SuperX application costs $0 to download and self-host. You still pay for the server, database storage, and any external APIs you choose to use. There is no SuperX subscription fee for running this code yourself."
    },
    %{
      question: "Which API keys do I need, and roughly what do they cost?",
      answer:
        "X_CLIENT_ID and X_CLIENT_SECRET are required for sign-in and publishing. As of August 2026, X lists text-post writes without a URL at $0.015 per request and qualifying owned-post reads at $0.001 per resource. An Anthropic or DeepSeek key is optional for AI features; the configured models range from $0.14 to about $5 per million uncached input or output tokens. TWITTERAPI_IO_KEY is optional for public-post discovery, feeds, mentions, and Signals at about $0.15 per 1,000 returned posts. VOYAGE_API_KEY is optional for semantic search at $0.18 per million tokens for the configured model. Provider prices can change."
    },
    %{
      question: "Does my data leave my server?",
      answer:
        "Your application records, encrypted X OAuth tokens, analytics snapshots, drafts, and contact lists are stored in your own Postgres database. Data does leave the box when a feature calls a service you configured: X for sign-in, reads, and publishing; Anthropic or DeepSeek for AI work; twitterapi.io for optional public X data; and Voyage for optional embeddings. SuperX does not include third-party product analytics or telemetry."
    },
    %{
      question: "Does SuperX work without an LLM key?",
      answer:
        "Yes, but without AI features. You can connect X, write and edit posts yourself, schedule them, publish the queue, and use the non-AI parts of the app. Voice-profile generation, post and reply drafting, Ask, article drafting, and AI lead scoring require an Anthropic or DeepSeek key."
    },
    %{
      question: "How is this different from superx.so?",
      answer:
        "SuperX is an open-source, self-hosted alternative, not the hosted superx.so service. You control the source, database, deployment, and provider accounts, and you do not pay a SuperX subscription. In return, you must handle setup, upgrades, backups, monitoring, and API bills yourself. Public-data features need a source you configure and fund, and the inspiration corpus grows on your instance rather than arriving as a bundled hosted library."
    }
  ]

  @page_description "SuperX is a free, open-source, self-hosted alternative to superx.so for drafting, scheduling, publishing, and measuring posts on X (Twitter)."

  @software_application %{
    "@type" => "SoftwareApplication",
    "name" => "SuperX",
    "description" => @page_description,
    "url" => "https://superx.free/",
    "codeRepository" => "https://github.com/ashishbishnoi18/superx",
    "applicationCategory" => "BusinessApplication",
    "operatingSystem" => "Linux with Docker",
    "isAccessibleForFree" => true,
    "offers" => %{
      "@type" => "Offer",
      "price" => "0",
      "priceCurrency" => "USD"
    }
  }

  def home(conn, _params) do
    conn
    |> assign(:x_configured, SuperX.X.configured?())
    |> assign(:features, @features)
    |> assign(:faqs, @faqs)
    |> assign(:page_title, "Free, open-source X growth tool")
    |> assign(:page_description, @page_description)
    |> assign(:canonical_url, "https://superx.free/")
    |> assign(:structured_data, structured_data())
    |> render(:home, layout: false)
  end

  defp redirect_if_authenticated(conn, _opts),
    do: SuperXWeb.UserAuth.redirect_if_authenticated(conn, [])

  defp structured_data do
    %{
      "@context" => "https://schema.org",
      "@graph" => [
        @software_application,
        %{
          "@type" => "FAQPage",
          "mainEntity" =>
            Enum.map(@faqs, fn faq ->
              %{
                "@type" => "Question",
                "name" => faq.question,
                "acceptedAnswer" => %{
                  "@type" => "Answer",
                  "text" => faq.answer
                }
              }
            end)
        }
      ]
    }
  end
end
