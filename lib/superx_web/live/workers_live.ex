defmodule SuperXWeb.WorkersLive do
  @moduledoc """
  Configures repeatable content batches without duplicating the shelf's
  review workflow.
  """

  use SuperXWeb, :live_view

  alias SuperX.Workers
  alias SuperX.Workers.ContentWorker

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(
        SuperX.PubSub,
        "workers:#{socket.assigns.current_x_account.id}"
      )
    end

    {:ok,
     socket
     |> assign(page_title: "Workers")
     |> assign(:editing, nil)
     |> assign(:form, nil)
     |> assign(:ai_configured, SuperX.AI.configured?())
     |> stream_configure(:workers, dom_id: &"worker-#{&1.id}")
     |> load()}
  end

  defp load(socket) do
    workers = Workers.list_content_workers(socket.assigns.current_x_account)
    stream(socket, :workers, workers, reset: true)
  end

  @impl true
  def handle_info({:worker_finished, _id, _count}, socket) do
    send(self(), :refresh_quota)
    {:noreply, load(socket)}
  end

  @impl true
  def handle_event("new", _params, socket) do
    worker = %ContentWorker{}

    {:noreply,
     socket
     |> assign(:editing, worker)
     |> assign_form(Workers.change_content_worker(worker))}
  end

  def handle_event("edit", %{"id" => id}, socket) do
    case find_worker(socket, id) do
      nil ->
        {:noreply, put_flash(socket, :error, "That worker no longer exists.")}

      worker ->
        {:noreply,
         socket |> assign(:editing, worker) |> assign_form(Workers.change_content_worker(worker))}
    end
  end

  def handle_event("cancel", _params, socket) do
    {:noreply, socket |> assign(:editing, nil) |> assign(:form, nil)}
  end

  def handle_event("validate", %{"content_worker" => params}, socket) do
    changeset =
      socket.assigns.editing
      |> Workers.change_content_worker(params)
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("save", %{"content_worker" => params}, socket) do
    result =
      case socket.assigns.editing do
        %ContentWorker{id: nil} ->
          Workers.create_content_worker(
            socket.assigns.current_user,
            socket.assigns.current_x_account,
            params
          )

        %ContentWorker{} = worker ->
          Workers.update_content_worker(worker, params)
      end

    case result do
      {:ok, _worker} ->
        {:noreply,
         socket
         |> assign(:editing, nil)
         |> assign(:form, nil)
         |> put_flash(:info, "Worker saved.")
         |> load()}

      {:error, changeset} ->
        {:noreply, assign_form(socket, Map.put(changeset, :action, :insert))}
    end
  end

  def handle_event("toggle", %{"id" => id}, socket) do
    case Workers.toggle_content_worker(
           socket.assigns.current_user,
           socket.assigns.current_x_account,
           id
         ) do
      {:ok, _worker} -> {:noreply, load(socket)}
      {:error, _reason} -> {:noreply, put_flash(socket, :error, "That worker no longer exists.")}
    end
  end

  def handle_event("run", %{"id" => id}, socket) do
    with true <- socket.assigns.ai_configured,
         %ContentWorker{} = worker <- find_worker(socket, id),
         {:ok, _job} <- Workers.enqueue(worker) do
      {:noreply, put_flash(socket, :info, "Batch queued. Drafts will appear in Ready to Post.")}
    else
      false ->
        {:noreply, put_flash(socket, :error, "Configure an LLM before running a worker.")}

      _ ->
        {:noreply, put_flash(socket, :error, "We couldn't run that worker.")}
    end
  end

  defp find_worker(socket, id) do
    Workers.get_content_worker(
      socket.assigns.current_user,
      socket.assigns.current_x_account,
      id
    )
  end

  defp assign_form(socket, changeset), do: assign(socket, :form, to_form(changeset))

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.page_header
      title="Workers"
      description="Workers write ready-to-post batches in your voice. Every draft lands on the existing shelf for review; nothing publishes on its own."
    >
      <:action>
        <button id="new-worker" phx-click="new" class="act-key whitespace-nowrap">
          New worker
        </button>
      </:action>
    </Layouts.page_header>

    <p :if={!@ai_configured} id="workers-ai-unconfigured" class="mb-8 text-muted-foreground">
      Configure an LLM before running a worker. You can set up the briefs and schedules now.
    </p>

    <.worker_form
      :if={@form}
      form={@form}
      editing={@editing}
      current_user={@current_user}
    />

    <div id="content-workers" phx-update="stream" class="border-t border-border">
      <div id="workers-empty" class="hidden py-16 text-center only:block">
        <p class="text-muted-foreground">
          No workers yet. Create one to turn a topic source into drafts you can review on the shelf.
        </p>
        <button phx-click="new" class="act-key mt-4">Create your first worker</button>
      </div>

      <section
        :for={{id, worker} <- @streams.workers}
        id={id}
        class="grid grid-cols-1 gap-5 border-b border-border py-6 sm:grid-cols-[minmax(0,1fr)_12rem_auto]"
      >
        <div class="min-w-0">
          <div class="flex flex-wrap items-baseline gap-x-3 gap-y-1">
            <h2 class="truncate text-[1rem] font-semibold">{worker.name}</h2>
            <span class={[
              "nb-mono text-[10px] uppercase tracking-[0.12em]",
              if(worker.enabled, do: "text-success", else: "text-faint")
            ]}>
              {if worker.enabled, do: "Enabled", else: "Disabled"}
            </span>
          </div>
          <p class="mt-1 text-[12px] text-muted-foreground">
            {ContentWorker.topic_source_label(worker.topic_source)}
          </p>
          <p
            :if={worker.topic_source == "products"}
            class="mt-2 max-w-[58ch] whitespace-pre-wrap text-[12px] leading-[1.6] text-faint"
          >
            {worker.product_context}
          </p>
        </div>

        <dl class="grid grid-cols-2 gap-x-4 gap-y-2 text-[11px] sm:grid-cols-1">
          <div>
            <dt class="nb-eyebrow text-[9px]">Batch</dt>
            <dd class="nb-mono mt-0.5 text-muted-foreground">
              {worker.batch_size} {if worker.batch_size == 1, do: "post", else: "posts"}
            </dd>
          </div>
          <div>
            <dt class="nb-eyebrow text-[9px]">Schedule</dt>
            <dd class="nb-mono mt-0.5 text-muted-foreground">{schedule_label(worker)}</dd>
          </div>
          <div>
            <dt class="nb-eyebrow text-[9px]">Last run</dt>
            <dd class="nb-mono mt-0.5 text-muted-foreground">
              {last_run_label(worker.last_run_at, @current_user.timezone)}
            </dd>
          </div>
        </dl>

        <div class="flex items-start gap-4 text-xs sm:justify-end">
          <button
            id={"run-worker-#{worker.id}"}
            phx-click="run"
            phx-value-id={worker.id}
            disabled={!@ai_configured}
            class="act-key whitespace-nowrap"
          >
            Run now
          </button>
          <button phx-click="edit" phx-value-id={worker.id} class="act">Edit</button>
          <button phx-click="toggle" phx-value-id={worker.id} class="act">
            {if worker.enabled, do: "Disable", else: "Enable"}
          </button>
        </div>
      </section>
    </div>
    """
  end

  attr :form, Phoenix.HTML.Form, required: true
  attr :editing, ContentWorker, required: true
  attr :current_user, :map, required: true

  defp worker_form(assigns) do
    ~H"""
    <section id="worker-editor" class="mb-9 border-y border-border py-6">
      <div class="mb-6 flex items-baseline justify-between gap-6">
        <div>
          <p class="nb-eyebrow">{if @editing.id, do: "Edit worker", else: "New worker"}</p>
          <h2 class="mt-1 text-[1.125rem] font-semibold">
            {if @editing.id, do: @editing.name, else: "Set the writing brief"}
          </h2>
        </div>
        <button type="button" phx-click="cancel" class="act text-xs">Cancel</button>
      </div>

      <.form for={@form} id="worker-form" phx-change="validate" phx-submit="save">
        <div class="grid grid-cols-1 gap-x-8 gap-y-5 sm:grid-cols-2">
          <.input field={@form[:name]} type="text" label="Name" placeholder="Product notes" required />

          <.input
            field={@form[:topic_source]}
            type="select"
            label="Topic source"
            options={
              Enum.map(ContentWorker.topic_sources(), &{ContentWorker.topic_source_label(&1), &1})
            }
          />

          <div :if={@form[:topic_source].value == "products"} class="sm:col-span-2">
            <.input
              field={@form[:product_context]}
              type="textarea"
              label="What are you building?"
              placeholder="Describe the product, who it is for, and the problems you are working through."
              rows="5"
              required
            />
          </div>

          <.input
            field={@form[:batch_size]}
            type="number"
            label="Posts per run"
            min="1"
            max="20"
            required
          />

          <.input
            field={@form[:cadence]}
            type="select"
            label="Cadence"
            prompt="On demand only"
            options={[{"Every day", "daily"}, {"Every week", "weekly"}]}
          />

          <.input
            :if={@form[:cadence].value == "weekly"}
            field={@form[:schedule_day]}
            type="select"
            label="Day"
            options={Enum.map(0..6, &{ContentWorker.day_name(&1), &1})}
          />

          <.input
            :if={@form[:cadence].value in ["daily", "weekly"]}
            field={@form[:schedule_time]}
            type="time"
            label={"Time in #{@current_user.timezone}"}
            required
          />

          <div class="sm:col-span-2">
            <.input
              field={@form[:enabled]}
              type="checkbox"
              label="Enabled for scheduled runs"
            />
            <p class="text-[11px] text-faint">Disabled workers can still be run by hand.</p>
          </div>
        </div>

        <div class="mt-6 flex items-center gap-5 text-xs">
          <button id="save-worker" type="submit" class="act-key">Save worker</button>
          <button type="button" phx-click="cancel" class="act">Cancel</button>
        </div>
      </.form>
    </section>
    """
  end

  defp schedule_label(%ContentWorker{cadence: nil}), do: "On demand"

  defp schedule_label(%ContentWorker{cadence: "daily", schedule_time: time}) do
    "Daily · #{format_time(time)}"
  end

  defp schedule_label(%ContentWorker{
         cadence: "weekly",
         schedule_day: day,
         schedule_time: time
       }) do
    "#{ContentWorker.day_name(day)} · #{format_time(time)}"
  end

  defp last_run_label(nil, _timezone), do: "Never"

  defp last_run_label(datetime, timezone) do
    case DateTime.shift_zone(datetime, timezone, Tz.TimeZoneDatabase) do
      {:ok, local} -> Calendar.strftime(local, "%d %b · %-I:%M %p")
      _ -> Calendar.strftime(datetime, "%d %b · %-I:%M %p UTC")
    end
  end

  defp format_time(%Time{} = time), do: Calendar.strftime(time, "%-I:%M %p")
end
