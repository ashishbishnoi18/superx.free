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
    message =
      if profile.source_post_ids == [] do
        "Built a starting voice from your profile; no posts were available."
      else
        "Learned your voice from your recent posts."
      end

    {:noreply,
     socket
     |> assign(:deriving, false)
     |> assign(:profile, profile)
     |> assign(:form, to_form(Content.change_voice_profile(profile)))
     |> put_flash(:info, message)}
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
    |> Map.update("inspiration_handles", [], &split_lines/1)
  end

  defp split_lines(value) when is_binary(value) do
    value |> String.split("\n") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
  end

  defp split_lines(value) when is_list(value), do: value
  defp split_lines(_), do: []

  # The field takes one handle per line, so the placeholder has to contain a
  # real newline. Written inline as `placeholder="@paulg\n@shl"` it is an
  # HTML attribute literal, where `\n` is not an escape and renders as the
  # two characters; written as `placeholder={"@paulg\n@shl"}` the HEEx
  # formatter unwraps the braces back to the literal form. A function call
  # is the form that survives both.
  defp handles_placeholder, do: "@paulg\n@shl"

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

    <.form
      for={@form}
      id="voice-profile-form"
      phx-change="validate"
      phx-submit="save"
      class="flex flex-col"
    >
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
        id="voice_profile_inspiration_handles"
        name="voice_profile[inspiration_handles]"
        label="Creator inspiration"
        hint="Up to three handles, one per line. Their posts supply ideas only — never voice, structure, or phrasing."
      >
        <.input
          field={@form[:inspiration_handles]}
          type="textarea"
          value={Enum.join(@form[:inspiration_handles].value || [], "\n")}
          rows="3"
          class="w-full textarea"
          placeholder={handles_placeholder()}
        />

        <p
          :if={(@form[:inspiration_handles].value || []) == []}
          id="creator-inspiration-empty"
          class="mt-2 text-[12px] leading-[1.6] text-faint"
        >
          No creators added. Writing will use your topics and the shared corpus.
        </p>
      </.field>

      <.field
        id="voice_profile_use_own_posts"
        name="voice_profile[use_own_posts]"
        label="Your examples"
        hint="Your published posts teach SuperX your register. Creator posts never appear in this voice evidence."
      >
        <label class="mt-4 flex items-center gap-2.5">
          <input type="hidden" name="voice_profile[use_own_posts]" value="false" />
          <input
            type="checkbox"
            name="voice_profile[use_own_posts]"
            value="true"
            checked={@form[:use_own_posts].value}
          /> Use my published posts as voice examples
        </label>
      </.field>

      <div id="engage-reply-settings" class="border-t border-border py-6">
        <p class="nb-eyebrow">Engage replies</p>
        <p class="mt-1 max-w-[42rem] text-[12px] leading-[1.6] text-faint">
          These preferences shape public replies drafted in Engage. Leaving either on its
          current setting preserves the existing behaviour.
        </p>
      </div>

      <.field
        id="voice_profile_reply_length"
        name="voice_profile[reply_length]"
        label="Reply length"
        hint="A target, not padding — replies still stop when the thought is complete."
      >
        <.input
          field={@form[:reply_length]}
          type="select"
          options={reply_length_options()}
          class="w-full select"
        />
      </.field>

      <.field
        id="voice_profile_reply_question_policy"
        name="voice_profile[reply_question_policy]"
        label="Questions back"
        hint="Choose whether a drafted reply should invite a response."
      >
        <.input
          field={@form[:reply_question_policy]}
          type="select"
          options={reply_question_options()}
          class="w-full select"
        />
      </.field>

      <div class="flex items-center gap-6 border-t border-border pt-6">
        <button type="submit" class="btn-primary" phx-disable-with="Saving…">
          <.icon name="hero-check" class="size-4" /> Save voice
        </button>
      </div>
    </.form>
    """
  end

  defp reply_length_options do
    [
      {"Current — usually under 120 characters", ""},
      {"Very short — usually under 80", "short"},
      {"Balanced — usually 80–180", "medium"},
      {"Detailed — usually 160–260", "long"}
    ]
  end

  defp reply_question_options do
    [
      {"When it fits — current behaviour", ""},
      {"Ask a relevant question", "ask"},
      {"Never ask a question", "never"}
    ]
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
