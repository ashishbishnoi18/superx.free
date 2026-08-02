defmodule SuperXWeb.ArticlesLive do
  @moduledoc """
  The long-form desk: account-scoped composition, review, and explicit
  publication through X's Article endpoints.
  """

  use SuperXWeb, :live_view

  alias SuperX.Articles
  alias SuperX.Articles.{Article, Writer}
  alias SuperX.Workers.PublishArticle

  @tabs ~w(draft ready published)

  @impl true
  def mount(_params, _session, socket) do
    article = %Article{}

    if connected?(socket) do
      Phoenix.PubSub.subscribe(
        SuperX.PubSub,
        "articles:#{socket.assigns.current_x_account.id}"
      )
    end

    {:ok,
     socket
     |> assign(page_title: "Articles")
     |> assign(:tabs, @tabs)
     |> assign(:tab, "draft")
     |> assign(:articles, [])
     |> assign(:counts, Map.new(@tabs, &{&1, 0}))
     |> assign(:article, nil)
     |> assign(:form, to_form(Articles.change_article(article)))
     |> assign(:ai_form, ai_form())
     |> assign(:ai_configured, SuperX.AI.configured?())
     |> assign(:generating, nil)
     |> assign(:composition_ref, nil)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    tab = if params["tab"] in @tabs, do: params["tab"], else: socket.assigns.tab
    socket = assign(socket, :tab, tab)

    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:article, nil)
    |> assign(:generating, nil)
    |> assign(:composition_ref, nil)
    |> load_list()
  end

  defp apply_action(socket, :new, _params) do
    article = %Article{}

    socket
    |> assign(page_title: "New article")
    |> assign(:article, article)
    |> assign(:form, to_form(Articles.change_article(article)))
    |> assign(:ai_form, ai_form())
    |> assign(:generating, nil)
    |> assign(:composition_ref, nil)
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    case scoped_article(socket, id) do
      nil ->
        socket
        |> put_flash(:error, "That article no longer exists.")
        |> push_navigate(to: ~p"/articles")

      article ->
        socket
        |> assign(page_title: article.title || "Untitled article")
        |> assign(:article, article)
        |> assign(:form, to_form(Articles.change_article(article)))
        |> assign(:ai_form, ai_form())
        |> assign(:generating, nil)
        |> assign(:composition_ref, nil)
    end
  end

  defp load_list(socket) do
    account = socket.assigns.current_x_account

    socket
    |> assign(:articles, Articles.list_articles(account, socket.assigns.tab))
    |> assign(:counts, Articles.counts(account))
  end

  @impl true
  def handle_event("validate", params, socket) do
    article_params = params["article"] || %{}
    ai_params = params["ai"] || %{}

    socket =
      case params["_target"] do
        ["ai", _field] ->
          socket
          |> assign(
            :form,
            to_form(Articles.change_article(socket.assigns.article, article_params))
          )
          |> assign(:ai_form, ai_form(ai_params))

        _article_change ->
          autosave(socket, article_params, ai_params)
      end

    {:noreply, socket}
  end

  def handle_event("article_action", %{"intent" => "ai_draft"} = params, socket) do
    {:noreply, compose_with_ai(socket, :draft, params)}
  end

  def handle_event("article_action", %{"intent" => "ai_extend"} = params, socket) do
    {:noreply, compose_with_ai(socket, :extend, params)}
  end

  def handle_event("article_action", %{"intent" => "mark_ready"} = params, socket) do
    {:noreply, save_article(socket, params["article"] || %{}, "ready")}
  end

  def handle_event("article_action", %{"intent" => "publish"} = params, socket) do
    {:noreply, publish_from_editor(socket, params["article"] || %{})}
  end

  def handle_event("article_action", params, socket) do
    {:noreply, save_article(socket, params["article"] || %{}, "draft")}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    with %Article{status: status} = article <- scoped_article(socket, id),
         true <- status in ["draft", "ready"],
         {:ok, _article} <- Articles.delete_article(article) do
      {:noreply, socket |> put_flash(:info, "Article deleted.") |> load_list()}
    else
      _ -> {:noreply, put_flash(socket, :error, "We couldn't delete that article.")}
    end
  end

  def handle_event("publish", %{"id" => id}, socket) do
    case scoped_article(socket, id) do
      %Article{status: "ready"} = article ->
        {:noreply, enqueue_publish(socket, article) |> load_list()}

      %Article{status: "published"} ->
        {:noreply, put_flash(socket, :error, "That article is already published.")}

      %Article{status: "publishing"} ->
        {:noreply, put_flash(socket, :info, "That article is already publishing.")}

      _article ->
        {:noreply, put_flash(socket, :error, "Only a ready article can be published.")}
    end
  end

  defp save_article(
         %{assigns: %{article: %Article{status: status}}} = socket,
         _params,
         _status
       )
       when status in ["publishing", "published"] do
    put_flash(socket, :error, "Articles are read-only once publishing starts.")
  end

  defp save_article(socket, params, status) do
    attrs = Map.put(params, "status", status)

    case persist(socket, attrs) do
      {:ok, _article} when status == "ready" ->
        socket
        |> put_flash(:info, "Article marked ready.")
        |> push_navigate(to: ~p"/articles?tab=ready")

      {:ok, article} ->
        socket
        |> assign(:article, article)
        |> assign(:form, to_form(Articles.change_article(article)))
        |> put_flash(:info, "Draft saved.")
        |> push_patch(to: ~p"/articles/#{article.id}/edit")

      {:error, %Ecto.Changeset{} = changeset} ->
        assign(socket, :form, to_form(changeset))

      {:error, reason} ->
        put_flash(socket, :error, save_error(reason))
    end
  end

  defp persist(%{assigns: %{article: %Article{id: nil}}} = socket, attrs) do
    Articles.create_article(
      socket.assigns.current_user,
      socket.assigns.current_x_account,
      attrs
    )
  end

  defp persist(socket, attrs), do: Articles.update_article(socket.assigns.article, attrs)

  defp autosave(%{assigns: %{article: %Article{status: status}}} = socket, params, ai)
       when status in ["publishing", "published"] do
    socket
    |> assign(:form, validation_form(socket.assigns.article, params))
    |> assign(:ai_form, ai_form(ai))
  end

  defp autosave(%{assigns: %{article: %Article{id: nil}}} = socket, params, ai)
       when params == %{} do
    assign(socket, :ai_form, ai_form(ai))
  end

  defp autosave(socket, params, ai) do
    if is_nil(socket.assigns.article.id) and blank?(params["title"]) and
         blank?(params["body"]) do
      socket
      |> assign(:form, validation_form(socket.assigns.article, params))
      |> assign(:ai_form, ai_form(ai))
    else
      # Editing work that was marked ready makes it a draft again. This is a
      # user-facing state change, but it is safer and more honest than keeping
      # an already-reviewed label on prose that has changed since review.
      attrs = Map.put(params, "status", "draft")
      new_article? = is_nil(socket.assigns.article.id)

      case persist(socket, attrs) do
        {:ok, article} ->
          socket
          |> assign(:article, article)
          |> assign(:form, to_form(Articles.change_article(article)))
          |> assign(:ai_form, ai_form(ai))
          |> maybe_move_to_saved_editor(new_article?)

        {:error, %Ecto.Changeset{} = changeset} ->
          socket
          |> assign(:form, to_form(Map.put(changeset, :action, :validate)))
          |> assign(:ai_form, ai_form(ai))

        {:error, reason} ->
          socket
          |> assign(:form, validation_form(socket.assigns.article, params))
          |> assign(:ai_form, ai_form(ai))
          |> put_flash(:error, save_error(reason))
      end
    end
  end

  defp validation_form(article, params) do
    article |> Articles.change_article(params) |> Map.put(:action, :validate) |> to_form()
  end

  defp maybe_move_to_saved_editor(socket, true) do
    push_patch(socket, to: ~p"/articles/#{socket.assigns.article.id}/edit")
  end

  defp maybe_move_to_saved_editor(socket, false), do: socket

  defp compose_with_ai(%{assigns: %{generating: mode}} = socket, _requested, _params)
       when not is_nil(mode),
       do: socket

  defp compose_with_ai(socket, mode, params) do
    article_params = params["article"] || %{}
    ai_params = params["ai"] || %{}

    attrs =
      article_params
      |> Map.put("instruction", ai_params["instruction"] || "")

    user = socket.assigns.current_user
    account = socket.assigns.current_x_account
    parent = self()
    composition_ref = make_ref()

    # Long-form generation should not freeze typing indicators or the rest
    # of the LiveView while the provider works through a large token budget.
    Task.Supervisor.start_child(SuperX.TaskSupervisor, fn ->
      send(
        parent,
        {:article_composed, composition_ref, Writer.compose(user, account, mode, attrs)}
      )
    end)

    socket
    |> assign(:form, to_form(Articles.change_article(socket.assigns.article, article_params)))
    |> assign(:ai_form, ai_form(ai_params))
    |> assign(:generating, mode)
    |> assign(:composition_ref, composition_ref)
  end

  @impl true
  def handle_info(
        {:article_composed, ref, {:ok, result}},
        %{assigns: %{composition_ref: active_ref}} = socket
      )
      when ref == active_ref do
    mode = socket.assigns.generating
    params = %{"title" => result.title, "body" => result.body, "status" => "draft"}
    new_article? = is_nil(socket.assigns.article.id)

    send(self(), :refresh_quota)

    case persist(socket, params) do
      {:ok, article} ->
        {:noreply,
         socket
         |> assign(:article, article)
         |> assign(:form, to_form(Articles.change_article(article)))
         |> assign(:ai_form, ai_form())
         |> assign(:generating, nil)
         |> assign(:composition_ref, nil)
         |> put_flash(:info, ai_success_message(mode))
         |> maybe_move_to_saved_editor(new_article?)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(:form, to_form(Map.put(changeset, :action, :validate)))
         |> assign(:ai_form, ai_form())
         |> assign(:generating, nil)
         |> assign(:composition_ref, nil)
         |> put_flash(
           :error,
           "The draft was written, but it needs an edit before it can be saved."
         )}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:form, validation_form(socket.assigns.article, params))
         |> assign(:ai_form, ai_form())
         |> assign(:generating, nil)
         |> assign(:composition_ref, nil)
         |> put_flash(:error, save_error(reason))}
    end
  end

  def handle_info({:article_publish_finished, id, :published}, socket) do
    {:noreply,
     socket
     |> refresh_published_article(id)
     |> put_flash(:info, "Article published on X.")}
  end

  def handle_info({:article_publish_finished, id, {:error, message}}, socket) do
    {:noreply,
     socket
     |> refresh_published_article(id)
     |> put_flash(:error, message)}
  end

  def handle_info(
        {:article_composed, ref, {:error, :quota_exceeded, _details}},
        %{assigns: %{composition_ref: active_ref}} = socket
      )
      when ref == active_ref do
    send(self(), :refresh_quota)

    {:noreply,
     socket
     |> assign(:generating, nil)
     |> assign(:composition_ref, nil)
     |> put_flash(:error, "You're out of AI credits for this window.")}
  end

  def handle_info(
        {:article_composed, ref, {:error, reason}},
        %{assigns: %{composition_ref: active_ref}} = socket
      )
      when ref == active_ref do
    require Logger
    Logger.warning("Article composition failed: #{inspect(reason)}")
    send(self(), :refresh_quota)

    {:noreply,
     socket
     |> assign(:generating, nil)
     |> assign(:composition_ref, nil)
     |> put_flash(:error, ai_error_message(reason))}
  end

  # Leaving the editor should not let a late provider response overwrite a
  # different article the user opened while it was in flight.
  def handle_info({:article_composed, _ref, _result}, socket) do
    send(self(), :refresh_quota)
    {:noreply, socket}
  end

  defp scoped_article(socket, id) do
    Articles.get_article(
      socket.assigns.current_user,
      socket.assigns.current_x_account,
      id
    )
  end

  defp publish_from_editor(%{assigns: %{article: %Article{status: "ready"}}} = socket, _params),
    do: enqueue_publish(socket, socket.assigns.article)

  defp publish_from_editor(socket, _params) do
    put_flash(socket, :error, "Only a ready article can be published.")
  end

  defp enqueue_publish(socket, article) do
    case PublishArticle.enqueue(article) do
      {:ok, claimed, _job} ->
        socket
        |> maybe_assign_article(claimed)
        |> put_flash(:info, "Publishing article…")

      {:error, :already_published} ->
        put_flash(socket, :error, "That article is already published.")

      {:error, :already_claimed} ->
        put_flash(socket, :info, "That article is already publishing.")

      {:error, _reason} ->
        put_flash(socket, :error, "We couldn't start publishing that article.")
    end
  end

  defp maybe_assign_article(
         %{assigns: %{article: %Article{id: id}}} = socket,
         %Article{id: id} = article
       ) do
    socket
    |> assign(:article, article)
    |> assign(:form, to_form(Articles.change_article(article)))
  end

  defp maybe_assign_article(socket, _article), do: socket

  defp refresh_published_article(%{assigns: %{article: nil}} = socket, _id), do: load_list(socket)

  defp refresh_published_article(
         %{assigns: %{article: %Article{id: id}}} = socket,
         id
       ) do
    case scoped_article(socket, id) do
      nil -> push_navigate(socket, to: ~p"/articles")
      article -> maybe_assign_article(socket, article)
    end
  end

  defp refresh_published_article(socket, _id), do: socket

  defp ai_form(params \\ %{}), do: to_form(params, as: :ai)

  @impl true
  def render(%{article: nil} = assigns), do: render_list(assigns)
  def render(assigns), do: render_editor(assigns)

  defp render_list(assigns) do
    ~H"""
    <Layouts.page_header
      title="Articles"
      description="A long-form desk for ideas that need more room than a post. Write, revise, review, and publish them to X."
    >
      <:action>
        <.link id="new-article" patch={~p"/articles/new"} class="act-key whitespace-nowrap">
          New article
        </.link>
      </:action>
    </Layouts.page_header>

    <div id="articles-tabs" class="mb-9 flex gap-6 border-b border-border">
      <.link
        :for={tab <- @tabs}
        id={"articles-tab-#{tab}"}
        patch={~p"/articles?tab=#{tab}"}
        class="tab"
        aria-selected={to_string(@tab == tab)}
      >
        {tab_label(tab)}
        <span class="nb-mono ml-1 text-[11px] text-faint">{Map.get(@counts, tab, 0)}</span>
      </.link>
    </div>

    <div :if={@articles == []} id="articles-empty" class="border-b border-border py-16 text-center">
      <p class="text-muted-foreground">{empty_message(@tab)}</p>
      <.link :if={@tab == "draft"} patch={~p"/articles/new"} class="act-key mt-3 inline-block text-xs">
        Start an article
      </.link>
    </div>

    <div id="articles-list" class="flex flex-col">
      <article
        :for={article <- @articles}
        id={"article-#{article.id}"}
        class="grid grid-cols-1 gap-4 border-b border-border py-6 sm:grid-cols-[minmax(0,1fr)_8rem_auto] sm:gap-7"
      >
        <div class="min-w-0">
          <.link
            :if={article.status != "published"}
            patch={~p"/articles/#{article.id}/edit"}
            class="hover-ember nb-display text-[1.125rem] leading-snug"
          >
            {display_title(article)}
          </.link>
          <p :if={article.status == "published"} class="nb-display text-[1.125rem] leading-snug">
            {display_title(article)}
          </p>

          <p class="mt-2 line-clamp-2 max-w-[66ch] text-[13px] leading-[1.65] text-muted-foreground">
            {excerpt(article.body)}
          </p>
          <p
            :if={article.publish_error}
            id={"article-publish-error-#{article.id}"}
            class="mt-2 text-[12px] leading-relaxed text-destructive"
          >
            {article.publish_error}
          </p>

          <div class="mt-3 flex flex-wrap items-center gap-4 text-xs">
            <.link
              :if={article.status != "published"}
              patch={~p"/articles/#{article.id}/edit"}
              class="act-key"
            >
              {if article.status == "publishing", do: "View", else: "Edit"}
            </.link>
            <a
              :if={article.permalink}
              href={article.permalink}
              target="_blank"
              rel="noopener"
              class="act"
            >
              View published article
            </a>
            <button
              :if={article.status == "ready"}
              id={"publish-article-#{article.id}"}
              phx-click="publish"
              phx-value-id={article.id}
              class="act-key"
              phx-disable-with="Publishing…"
            >
              Publish
            </button>
            <span
              :if={article.status == "publishing"}
              id={"article-publishing-#{article.id}"}
              class="nb-mono text-[11px] text-primary"
            >
              Publishing…
            </span>
            <button
              :if={article.status in ["draft", "ready"]}
              phx-click="delete"
              phx-value-id={article.id}
              data-confirm="Delete this article?"
              class="act-danger"
            >
              Delete
            </button>
          </div>
        </div>

        <p class="nb-mono text-[11px] leading-[1.9] text-faint">
          {word_label(article.word_count)}<br />
          {article_date(article)}
        </p>

        <span class={state_class(article.status)}>{state_label(article.status)}</span>
      </article>
    </div>
    """
  end

  defp render_editor(assigns) do
    ~H"""
    <div class="mx-auto max-w-[66ch]">
      <header class="mb-9 flex items-center justify-between gap-6 border-b border-border pb-4">
        <div class="flex min-w-0 items-center gap-3">
          <.link
            id="articles-editor-back"
            patch={~p"/articles?tab=#{article_tab(@article.status)}"}
            class="act text-xs"
          >
            Articles
          </.link>
          <span class="text-faint">/</span>
          <span class="nb-eyebrow truncate">{editor_state(@article)}</span>
        </div>
        <span class="nb-mono shrink-0 text-[11px] text-faint">
          {word_label(Article.count_words(@form[:body].value))}
        </span>
      </header>

      <.form
        for={@form}
        id="article-editor-form"
        phx-change="validate"
        phx-submit="article_action"
        class="flex flex-col"
      >
        <.input
          field={@form[:title]}
          id="article-title"
          type="text"
          placeholder="Title"
          aria-label="Article title"
          readonly={not editable?(@article) or not is_nil(@generating)}
          phx-debounce="250"
          class="w-full border-0 bg-transparent px-0 py-2 font-display text-[2.25rem] font-semibold leading-[1.08] tracking-[-0.035em] text-foreground placeholder:text-faint focus:outline-none"
        />

        <.input
          field={@form[:body]}
          id="article-body"
          type="textarea"
          rows="22"
          placeholder="Begin with the part you can't fit into a post."
          aria-label="Article body"
          readonly={not editable?(@article) or not is_nil(@generating)}
          phx-debounce="250"
          class="mt-9 min-h-[32rem] w-full resize-y border-0 bg-transparent px-0 py-2 text-[1.0625rem] leading-[1.9] tracking-[-0.008em] text-foreground placeholder:text-faint focus:outline-none"
        />

        <div class="mt-4 flex flex-wrap items-center gap-5 border-t border-border pt-4 text-xs">
          <button
            :if={editable?(@article)}
            id="save-article-draft"
            type="submit"
            name="intent"
            value="save_draft"
            class="act"
            disabled={not is_nil(@generating)}
            phx-disable-with="Saving…"
          >
            Save draft
          </button>
          <button
            :if={editable?(@article)}
            id="mark-article-ready"
            type="submit"
            name="intent"
            value="mark_ready"
            class="act-key"
            disabled={not is_nil(@generating)}
            phx-disable-with="Saving…"
          >
            {if @article.status == "ready", do: "Save ready", else: "Mark ready"}
          </button>
          <button
            :if={@article.status == "ready"}
            id="publish-article"
            type="submit"
            name="intent"
            value="publish"
            class="act-key"
            disabled={not is_nil(@generating)}
            phx-disable-with="Publishing…"
          >
            Publish
          </button>
          <span
            :if={@article.status == "publishing"}
            id="article-publishing"
            class="nb-mono text-[11px] text-primary"
          >
            Publishing…
          </span>
          <span :if={@article.status == "published"} class="text-muted-foreground">
            Published articles are read-only here.
          </span>
          <a
            :if={@article.status == "published" and @article.permalink}
            id="published-article-permalink"
            href={@article.permalink}
            target="_blank"
            rel="noopener"
            class="act"
          >
            View on X
          </a>
          <span class="nb-mono ml-auto text-[11px] text-faint">
            Changes save automatically · {Article.count_words(@form[:body].value)} words
          </span>
        </div>

        <p
          :if={@article.publish_error}
          id="article-publish-error"
          class="mt-4 text-[13px] leading-relaxed text-destructive"
        >
          {@article.publish_error}
        </p>

        <section
          :if={editable?(@article)}
          id="article-ai-assistance"
          class="mt-9 border-t border-border pt-6"
        >
          <div class="mb-4 flex items-baseline justify-between gap-5">
            <div>
              <p class="nb-eyebrow">Writing assistance</p>
              <p class="mt-1 text-[12px] text-faint">
                One composition uses {Writer.credit_cost()} credit.
              </p>
            </div>
            <span :if={@generating} class="nb-mono text-[11px] text-primary">
              {generating_label(@generating)}
            </span>
          </div>

          <p :if={!@ai_configured} class="text-muted-foreground">
            Configure an LLM provider to draft or continue this article in your voice.
          </p>

          <div :if={@ai_configured}>
            <.input
              field={@ai_form[:instruction]}
              id="article-ai-instruction"
              type="textarea"
              rows="3"
              label={ai_label(@form[:body].value)}
              placeholder={ai_placeholder(@form[:body].value)}
              readonly={not is_nil(@generating)}
              phx-debounce="250"
              class="w-full resize-y border-x-0 border-b border-t-0 border-input bg-transparent px-0 py-2 leading-[1.65] text-foreground placeholder:text-faint focus:border-primary focus:outline-none"
            />

            <button
              id="compose-article-with-ai"
              type="submit"
              name="intent"
              value={ai_intent(@form[:body].value)}
              class="act-key mt-3"
              disabled={not is_nil(@generating)}
              phx-disable-with="Writing…"
            >
              {ai_button_label(@form[:body].value)}
            </button>
          </div>
        </section>
      </.form>
    </div>
    """
  end

  defp editable?(%Article{status: status}), do: status in ["draft", "ready"]

  defp display_title(%Article{title: title}) when is_binary(title) and title != "", do: title
  defp display_title(_article), do: "Untitled article"

  defp excerpt(body) when is_binary(body) and body != "" do
    body |> String.replace(~r/\s+/u, " ") |> String.trim()
  end

  defp excerpt(_body), do: "No body yet."

  defp article_date(%Article{status: "published", published_at: at}) when not is_nil(at),
    do: Calendar.strftime(at, "%-d %b %Y")

  defp article_date(%Article{updated_at: at}), do: Calendar.strftime(at, "%-d %b %Y")

  defp word_label(1), do: "1 word"
  defp word_label(count), do: "#{count || 0} words"

  defp state_class("published"), do: "nb-mono text-[11px] tracking-[0.04em] text-success"
  defp state_class("publishing"), do: "nb-mono text-[11px] tracking-[0.04em] text-primary"
  defp state_class("ready"), do: "nb-mono text-[11px] tracking-[0.04em] text-primary"
  defp state_class(_status), do: "nb-mono text-[11px] tracking-[0.04em] text-faint"

  defp editor_state(%Article{id: nil}), do: "New draft"
  defp editor_state(%Article{status: "published"}), do: "Published"
  defp editor_state(%Article{status: "publishing"}), do: "Publishing"
  defp editor_state(%Article{status: "ready"}), do: "Ready"
  defp editor_state(_article), do: "Draft"

  defp tab_label("draft"), do: "Drafts"
  defp tab_label("ready"), do: "Ready"
  defp tab_label("published"), do: "Published"

  defp empty_message("draft"), do: "No drafts. Give the first unfinished idea somewhere to live."
  defp empty_message("ready"), do: "Nothing ready yet. Finished drafts appear here for review."

  defp empty_message("published"),
    do: "Nothing published yet. Ready articles can go to X when you approve them."

  defp article_tab("publishing"), do: "ready"
  defp article_tab(status), do: status

  defp state_label("publishing"), do: "publishing…"
  defp state_label(status), do: status

  defp ai_intent(body), do: if(blank?(body), do: "ai_draft", else: "ai_extend")

  defp ai_button_label(body),
    do: if(blank?(body), do: "Draft from this brief", else: "Continue the draft")

  defp ai_label(body), do: if(blank?(body), do: "Brief", else: "Where should it go next?")

  defp ai_placeholder(body) do
    if blank?(body) do
      "The claim, experience, or argument this article should develop…"
    else
      "Optional direction for the next section or the ending…"
    end
  end

  defp generating_label(:draft), do: "drafting…"
  defp generating_label(:extend), do: "continuing…"
  defp generating_label(_mode), do: "writing…"

  defp ai_success_message(:extend), do: "Added new paragraphs and saved the draft."
  defp ai_success_message(_mode), do: "Draft written and saved."

  defp ai_error_message(:missing_brief), do: "Give the writer a brief first."
  defp ai_error_message(:empty_article), do: "Write something before asking it to continue."
  defp ai_error_message(_reason), do: "Couldn't write that just now. Try again in a moment."

  defp save_error(:account_mismatch), do: "That account doesn't belong to this user."
  defp save_error(:read_only), do: "That article is already publishing or published."
  defp save_error(_reason), do: "We couldn't save that article."

  defp blank?(value), do: not is_binary(value) or String.trim(value) == ""
end
