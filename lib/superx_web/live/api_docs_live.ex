defmodule SuperXWeb.ApiDocsLive do
  @moduledoc """
  The programmatic boundary, documented beside the credentials that grant
  access to it.

  Keeping the reference inside the application lets a self-hosted instance
  describe its own plan limits without sending operators to hosted docs that
  may describe a different release.
  """

  use SuperXWeb, :live_view

  alias SuperX.Billing.Plan

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "API", plans: Plan.all())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="api-docs">
      <Layouts.page_header
        title="API"
        description="Read account data and put approved writing into the queue from your own scripts. Nothing here publishes directly."
      >
        <:action>
          <.link navigate={~p"/accounts"} class="act whitespace-nowrap">Manage tokens</.link>
        </:action>
      </Layouts.page_header>

      <section id="api-authentication" class="border-t border-border py-6">
        <div class="grid grid-cols-1 gap-7 sm:grid-cols-[14rem_minmax(0,1fr)]">
          <div>
            <h2 class="text-[15px] font-semibold">Authentication</h2>
            <p class="mt-1 text-[12px] leading-[1.6] text-faint">
              Tokens are created and revoked under Accounts.
            </p>
          </div>
          <div class="min-w-0">
            <p class="max-w-[68ch] text-sm leading-6 text-muted-foreground">
              Send the token in the
              <code class="nb-mono text-[12px] text-foreground">Authorization</code>
              header. It acts on the X account selected in Accounts.
            </p>
            <pre class="nb-mono mt-4 overflow-x-auto border-y border-border py-4 text-[12px] leading-6 text-foreground"><code>Authorization: Bearer sx_prefix.secret</code></pre>
          </div>
        </div>
      </section>

      <section id="api-endpoints" class="border-t border-border py-6">
        <div class="grid grid-cols-1 gap-7 sm:grid-cols-[14rem_minmax(0,1fr)]">
          <div>
            <h2 class="text-[15px] font-semibold">Endpoints</h2>
            <p class="mt-1 text-[12px] leading-[1.6] text-faint">
              JSON request and response bodies throughout.
            </p>
          </div>
          <div class="min-w-0 divide-y divide-border border-y border-border">
            <.endpoint
              method="GET"
              path="/api/queue"
              description="List one queue state. status defaults to scheduled."
            />
            <.endpoint
              method="GET"
              path="/api/shelf"
              description="List drafts waiting on Ready to Post and their counts."
            />
            <.endpoint
              method="GET"
              path="/api/analytics"
              description="Read a 7, 30, or 90-day analytics summary."
            />
            <.endpoint
              method="POST"
              path="/api/posts"
              description="Create a draft from segments. Client-supplied status is ignored."
            />
            <.endpoint
              method="POST"
              path="/api/posts/:id/schedule"
              description="Queue an owned draft at the next opening, or pass at as an ISO 8601 time."
            />
            <.endpoint
              method="DELETE"
              path="/api/posts/:id"
              description="Delete an owned local post. This never deletes anything from X."
            />
          </div>
        </div>
      </section>

      <section id="api-write-shapes" class="border-t border-border py-6">
        <div class="grid grid-cols-1 gap-7 sm:grid-cols-[14rem_minmax(0,1fr)]">
          <div>
            <h2 class="text-[15px] font-semibold">Writing</h2>
            <p class="mt-1 text-[12px] leading-[1.6] text-faint">
              Creation and scheduling stay separate by design.
            </p>
          </div>
          <div class="min-w-0 space-y-6">
            <div>
              <p class="nb-eyebrow">Create a draft</p>
              <pre
                phx-no-curly-interpolation
                class="nb-mono mt-3 overflow-x-auto border-y border-border py-4 text-[12px] leading-6 text-foreground"
              ><code>POST /api/posts
    {"segments":[{"text":"Approved copy","media_ids":[]}],"tags":["launch"]}</code></pre>
            </div>
            <div>
              <p class="nb-eyebrow">Choose the next opening</p>
              <pre class="nb-mono mt-3 overflow-x-auto border-y border-border py-4 text-[12px] leading-6 text-foreground"><code>POST /api/posts/:id/schedule</code></pre>
            </div>
            <div>
              <p class="nb-eyebrow">Choose an explicit time</p>
              <pre
                phx-no-curly-interpolation
                class="nb-mono mt-3 overflow-x-auto border-y border-border py-4 text-[12px] leading-6 text-foreground"
              ><code>POST /api/posts/:id/schedule
    {"at":"2030-08-02T09:30:00Z"}</code></pre>
            </div>
          </div>
        </div>
      </section>

      <section id="api-limits" class="border-t border-border py-6">
        <div class="grid grid-cols-1 gap-7 sm:grid-cols-[14rem_minmax(0,1fr)]">
          <div>
            <h2 class="text-[15px] font-semibold">Limits</h2>
            <p class="mt-1 text-[12px] leading-[1.6] text-faint">
              Shared by all tokens belonging to one user.
            </p>
          </div>
          <div>
            <div class="grid grid-cols-2 border-y border-border sm:grid-cols-4">
              <div :for={plan <- @plans} class="py-3 sm:pr-5">
                <p class="nb-eyebrow">{plan.name}</p>
                <p class="nb-mono mt-1 text-[12px] text-foreground">
                  {Plan.limit(plan.tier, :api_requests_minute)} req/min
                </p>
              </div>
            </div>
            <p class="mt-4 max-w-[68ch] text-sm leading-6 text-muted-foreground">
              Every authenticated response includes <code class="nb-mono text-[12px] text-foreground">RateLimit-Limit</code>, <code class="nb-mono text-[12px] text-foreground">RateLimit-Remaining</code>, and <code class="nb-mono text-[12px] text-foreground">RateLimit-Reset</code>. A 429 response also includes <code class="nb-mono text-[12px] text-foreground">Retry-After</code>. Counters live on this single node
              and start fresh when the application restarts.
            </p>
          </div>
        </div>
      </section>

      <section id="api-errors" class="border-y border-border py-6">
        <div class="grid grid-cols-1 gap-7 sm:grid-cols-[14rem_minmax(0,1fr)]">
          <div>
            <h2 class="text-[15px] font-semibold">Errors</h2>
            <p class="mt-1 text-[12px] leading-[1.6] text-faint">
              Stable shapes for scripts to branch on.
            </p>
          </div>
          <div class="min-w-0 space-y-5 text-sm leading-6 text-muted-foreground">
            <p>
              Authentication, ownership, scheduling, and limit failures use
              <code phx-no-curly-interpolation class="nb-mono text-[12px] text-foreground">
                {"error":"message"}
              </code>
              with 401, 404, 409, 422, or 429.
            </p>
            <p>
              Content validation returns field messages in
              <code phx-no-curly-interpolation class="nb-mono text-[12px] text-foreground">
                {"errors":{"segments":["post 1 is over 280 characters"]}}
              </code>
              with 422. These are the same messages shown by the composer.
            </p>
          </div>
        </div>
      </section>
    </div>
    """
  end

  attr :method, :string, required: true
  attr :path, :string, required: true
  attr :description, :string, required: true

  defp endpoint(assigns) do
    ~H"""
    <div class="grid grid-cols-1 gap-1 py-3 sm:grid-cols-[minmax(15rem,auto)_1fr] sm:gap-6">
      <p class="nb-mono text-[12px] text-foreground">
        <span class="text-primary">{@method}</span> {@path}
      </p>
      <p class="text-[13px] leading-5 text-muted-foreground">{@description}</p>
    </div>
    """
  end
end
