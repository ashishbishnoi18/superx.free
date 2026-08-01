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
    <Layouts.page_header
      title="Your voice"
      description="What SuperX knows about how you write. Everything here is editable — the analysis is a starting point, not a verdict."
    >
      <:action>
        <button
          :if={@ai_configured}
          phx-click="derive"
          disabled={@deriving}
          class="act-key whitespace-nowrap"
        >
          {if @deriving, do: "Reading your posts…", else: "Learn from my posts"}
        </button>
      </:action>
    </Layouts.page_header>

    <p :if={!@ai_configured} class="mb-6 text-muted-foreground">
      Set <code class="nb-mono text-[12px] text-foreground">ANTHROPIC_API_KEY</code>
      to learn this automatically. You can still fill it in by hand.
    </p>

    <p :if={@profile.generated_at} class="nb-mono mb-8 text-[11px] text-faint">
      last learned {Calendar.strftime(@profile.generated_at, "%-d %b %Y")} · {length(
        @profile.source_post_ids
      )} posts
    </p>

    <.form for={@form} phx-change="validate" phx-submit="save" class="flex flex-col">
      <.field
        id="voice_profile_about"
        name="voice_profile[about]"
        label="About you"
        hint="Written in first person. This anchors everything SuperX writes."
      >
        <textarea
          id="voice_profile_about"
          name="voice_profile[about]"
          rows="5"
          class="textarea"
          placeholder="I write about…"
        >{@form[:about].value}</textarea>
      </.field>

      <.field
        id="voice_profile_topics"
        name="voice_profile[topics]"
        label="Topics"
        hint="Comma-separated. These steer which posts SuperX learns from."
      >
        <input
          type="text"
          id="voice_profile_topics"
          name="voice_profile[topics]"
          value={@form[:topics].value}
          class="input"
          placeholder="startups, writing, product design"
        />
      </.field>

      <.field
        id="voice_profile_style_notes"
        name="voice_profile[style_notes]"
        label="How you write"
        hint="Mechanics: sentence length, capitalisation, punctuation, emoji."
      >
        <textarea
          id="voice_profile_style_notes"
          name="voice_profile[style_notes]"
          rows="4"
          class="textarea"
          placeholder="Short declarative sentences. Lowercase openings. No emoji."
        >{@form[:style_notes].value}</textarea>
      </.field>

      <.field
        id="voice_profile_rules"
        name="voice_profile[rules]"
        label="Your rules"
        hint="Instructions that override everything else. Kept when you re-learn."
      >
        <textarea
          id="voice_profile_rules"
          name="voice_profile[rules]"
          rows="4"
          class="textarea"
          placeholder="Never use the word 'journey'. Never post before 9am."
        >{@form[:rules].value}</textarea>
      </.field>

      <.field
        id="voice_profile_questions"
        name="voice_profile[questions]"
        label="Questions you can answer"
        hint="One per line. Used as writing prompts."
      >
        <textarea
          id="voice_profile_questions"
          name="voice_profile[questions]"
          rows="4"
          class="textarea"
        >{Enum.join(@form[:questions].value || [], "\n")}</textarea>
      </.field>

      <.field
        id="voice_profile_favorite_voices"
        name="voice_profile[favorite_voices]"
        label="Voices you admire"
        hint="One handle per line. SuperX leans toward how they structure a post."
      >
        <textarea
          id="voice_profile_favorite_voices"
          name="voice_profile[favorite_voices]"
          rows="3"
          class="textarea"
          placeholder="@paulg"
        >{Enum.join(@form[:favorite_voices].value || [], "\n")}</textarea>

        <label class="mt-4 flex items-center gap-2.5">
          <input type="hidden" name="voice_profile[use_own_posts]" value="false" />
          <input
            type="checkbox"
            name="voice_profile[use_own_posts]"
            value="true"
            checked={@form[:use_own_posts].value}
          /> Show SuperX my published posts as examples
        </label>
      </.field>

      <div class="flex items-center gap-6 border-t border-border pt-6 text-xs">
        <button type="submit" class="act-key">Save voice</button>
      </div>
    </.form>
    """
  end

  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :hint, :string, default: nil
  slot :inner_block, required: true

  defp field(assigns) do
    ~H"""
    <div class="grid grid-cols-1 gap-7 border-t border-border py-6 sm:grid-cols-[14rem_minmax(0,1fr)]">
      <div>
        <label class="label" for={@id}>{@label}</label>
        <p :if={@hint} class="text-[12px] leading-[1.6] text-faint">{@hint}</p>
      </div>
      <div>{render_slot(@inner_block)}</div>
    </div>
    """
  end
end
