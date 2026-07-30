defmodule SuperXWeb.VoiceLive do
  @moduledoc """
  Review and edit the learned writing voice.

  Everything here is editable: the derivation is a starting point, and a
  user who disagrees with it should be able to overrule it rather than
  regenerate until it guesses right.
  """

  use SuperXWeb, :live_view

  alias SuperX.Content
  alias SuperX.Content.Voice

  @impl true
  def mount(_params, _session, socket) do
    {:ok, profile} = Content.get_or_create_voice_profile(socket.assigns.current_x_account)

    {:ok,
     socket
     |> assign(page_title: "Voice")
     |> assign(:profile, profile)
     |> assign(:deriving, false)
     |> assign(:ai_configured, SuperX.AI.configured?())
     |> assign(:form, to_form(Content.change_voice_profile(profile)))}
  end

  @impl true
  def handle_event("validate", %{"voice_profile" => params}, socket) do
    changeset =
      socket.assigns.profile
      |> Content.change_voice_profile(normalize(params))
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  def handle_event("save", %{"voice_profile" => params}, socket) do
    case Content.update_voice_profile(socket.assigns.profile, normalize(params)) do
      {:ok, profile} ->
        {:noreply,
         socket
         |> assign(:profile, profile)
         |> assign(:form, to_form(Content.change_voice_profile(profile)))
         |> put_flash(:info, "Voice saved.")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  def handle_event("derive", _params, socket) do
    account = socket.assigns.current_x_account
    parent = self()

    Task.Supervisor.start_child(SuperX.TaskSupervisor, fn ->
      send(parent, {:derived, Voice.derive(account)})
    end)

    {:noreply, assign(socket, :deriving, true)}
  end

  @impl true
  def handle_info({:derived, {:ok, profile}}, socket) do
    {:noreply,
     socket
     |> assign(:deriving, false)
     |> assign(:profile, profile)
     |> assign(:form, to_form(Content.change_voice_profile(profile)))
     |> put_flash(:info, "Learned your voice from your recent posts.")}
  end

  def handle_info({:derived, {:error, :reauth_required}}, socket) do
    {:noreply,
     socket
     |> assign(:deriving, false)
     |> put_flash(:error, "Reconnect your X account so SuperX can read your posts.")
     |> push_navigate(to: ~p"/accounts")}
  end

  def handle_info({:derived, {:error, reason}}, socket) do
    require Logger
    Logger.warning("Voice derivation failed: #{inspect(reason)}")

    {:noreply,
     socket
     |> assign(:deriving, false)
     |> put_flash(:error, "Couldn't analyse your posts just now.")}
  end

  # Textareas submit one handle or question per line.
  defp normalize(params) do
    params
    |> Map.update("questions", [], &split_lines/1)
    |> Map.update("favorite_voices", [], &split_lines/1)
  end

  defp split_lines(value) when is_binary(value) do
    value |> String.split("\n") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
  end

  defp split_lines(value) when is_list(value), do: value
  defp split_lines(_), do: []

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex items-start justify-between gap-4">
        <div>
          <h1 class="text-2xl font-bold tracking-tight">Your voice</h1>
          <p class="mt-1 text-sm" style="color: var(--text-secondary)">
            What SuperX knows about how you write. Edit anything it got wrong.
          </p>
        </div>

        <button
          :if={@ai_configured}
          phx-click="derive"
          disabled={@deriving}
          class="btn btn-secondary shrink-0"
        >
          <.icon
            name={if @deriving, do: "hero-arrow-path", else: "hero-sparkles"}
            class={["size-4", @deriving && "animate-spin"]}
          />
          {if @deriving, do: "Reading your posts…", else: "Learn from my posts"}
        </button>
      </div>

      <div :if={!@ai_configured} class="card p-4 text-sm">
        <p class="font-semibold">No LLM configured</p>
        <p class="mt-1" style="color: var(--text-secondary)">
          Set <code class="font-mono text-xs">ANTHROPIC_API_KEY</code>
          to learn your voice automatically. You can still fill this in by hand.
        </p>
      </div>

      <p :if={@profile.generated_at} class="text-xs" style="color: var(--text-muted)">
        Last learned {Calendar.strftime(@profile.generated_at, "%-d %b %Y")}
        from {length(@profile.source_post_ids)} posts.
      </p>

      <.form for={@form} phx-change="validate" phx-submit="save" class="space-y-5">
        <div class="card p-5">
          <label class="label" for="voice_profile_about">About you</label>
          <p class="mb-2 text-xs" style="color: var(--text-secondary)">
            Written in first person. This anchors everything SuperX writes.
          </p>
          <textarea
            id="voice_profile_about"
            name="voice_profile[about]"
            rows="5"
            class="textarea"
            placeholder="I write about…"
          >{@form[:about].value}</textarea>
        </div>

        <div class="card p-5">
          <label class="label" for="voice_profile_topics">Topics</label>
          <p class="mb-2 text-xs" style="color: var(--text-secondary)">
            Comma-separated. These steer which posts SuperX learns from.
          </p>
          <input
            type="text"
            id="voice_profile_topics"
            name="voice_profile[topics]"
            value={@form[:topics].value}
            class="input"
            placeholder="startups, writing, product design"
          />
        </div>

        <div class="card p-5">
          <label class="label" for="voice_profile_style_notes">How you write</label>
          <p class="mb-2 text-xs" style="color: var(--text-secondary)">
            Mechanics: sentence length, capitalisation, punctuation, emoji.
          </p>
          <textarea
            id="voice_profile_style_notes"
            name="voice_profile[style_notes]"
            rows="4"
            class="textarea"
            placeholder="Short declarative sentences. Lowercase openings. No emoji."
          >{@form[:style_notes].value}</textarea>
        </div>

        <div class="card p-5">
          <label class="label" for="voice_profile_rules">Your rules</label>
          <p class="mb-2 text-xs" style="color: var(--text-secondary)">
            Instructions that override everything else. Kept when you re-learn.
          </p>
          <textarea
            id="voice_profile_rules"
            name="voice_profile[rules]"
            rows="4"
            class="textarea"
            placeholder="Never use the word 'journey'. Never post before 9am."
          >{@form[:rules].value}</textarea>
        </div>

        <div class="card p-5">
          <label class="label" for="voice_profile_questions">Questions you can answer</label>
          <p class="mb-2 text-xs" style="color: var(--text-secondary)">
            One per line. Used as writing prompts.
          </p>
          <textarea
            id="voice_profile_questions"
            name="voice_profile[questions]"
            rows="4"
            class="textarea"
          >{Enum.join(@form[:questions].value || [], "\n")}</textarea>
        </div>

        <div class="card p-5">
          <label class="label" for="voice_profile_favorite_voices">Voices you admire</label>
          <p class="mb-2 text-xs" style="color: var(--text-secondary)">
            One handle per line. SuperX will lean toward how they structure posts.
          </p>
          <textarea
            id="voice_profile_favorite_voices"
            name="voice_profile[favorite_voices]"
            rows="3"
            class="textarea"
            placeholder="@paulg"
          >{Enum.join(@form[:favorite_voices].value || [], "\n")}</textarea>

          <label class="mt-4 flex items-center gap-2.5 text-sm">
            <input type="hidden" name="voice_profile[use_own_posts]" value="false" />
            <input
              type="checkbox"
              name="voice_profile[use_own_posts]"
              value="true"
              checked={@form[:use_own_posts].value}
              class="size-4 rounded"
            />
            Show SuperX my published posts as examples when writing
          </label>
        </div>

        <div class="flex justify-end">
          <button type="submit" class="btn btn-primary">Save voice</button>
        </div>
      </.form>
    </div>
    """
  end
end
