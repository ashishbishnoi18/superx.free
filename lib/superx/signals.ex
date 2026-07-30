defmodule SuperX.Signals do
  @moduledoc """
  Watch agents and the leads they find.
  """

  import Ecto.Query

  alias SuperX.Accounts.XAccount
  alias SuperX.Repo
  alias SuperX.Signals.{Agent, Lead}

  # --- Agents --------------------------------------------------------------

  def list_agents(%XAccount{} = account) do
    Agent
    |> where(x_account_id: ^account.id)
    |> order_by(asc: :inserted_at)
    |> Repo.all()
  end

  def get_agent(%XAccount{} = account, id), do: Repo.get_by(Agent, id: id, x_account_id: account.id)

  def create_agent(%XAccount{} = account, attrs) do
    %Agent{}
    |> Agent.changeset(Map.put(attrs, :x_account_id, account.id))
    |> Repo.insert()
  end

  def update_agent(%Agent{} = agent, attrs) do
    agent |> Agent.changeset(attrs) |> Repo.update()
  end

  def delete_agent(%XAccount{} = account, id) do
    case get_agent(account, id) do
      nil -> {:error, :not_found}
      agent -> Repo.delete(agent)
    end
  end

  def toggle_agent(%XAccount{} = account, id) do
    case get_agent(account, id) do
      nil -> {:error, :not_found}
      agent -> update_agent(agent, %{enabled: not agent.enabled})
    end
  end

  @doc "Agents due a run, least-recently-run first."
  def agents_due(within_minutes \\ 360) do
    cutoff = DateTime.utc_now() |> DateTime.add(-within_minutes * 60, :second)

    Agent
    |> where([a], a.enabled)
    |> where([a], is_nil(a.last_run_at) or a.last_run_at <= ^cutoff)
    |> order_by([a], asc_nulls_first: a.last_run_at)
    |> preload(:x_account)
    |> Repo.all()
  end

  def record_run(%Agent{} = agent, found, error \\ nil) do
    agent
    |> Ecto.Changeset.change(
      last_run_at: DateTime.utc_now() |> DateTime.truncate(:second),
      last_error: error,
      leads_found: agent.leads_found + found
    )
    |> Repo.update()
  end

  @doc "How many agents the user's plan allows."
  def agent_limit(user), do: SuperX.Billing.Plan.limit(SuperX.Billing.tier(user), :signal_agents)

  # --- Leads ---------------------------------------------------------------

  def list_leads(%XAccount{} = account, opts \\ []) do
    Lead
    |> where(x_account_id: ^account.id)
    |> filter_status(opts[:status])
    |> order_by([l], desc: fragment("coalesce(?, 0)", l.score), desc: l.inserted_at)
    |> limit(^(opts[:limit] || 100))
    |> preload(:signal_agent)
    |> Repo.all()
  end

  defp filter_status(query, nil), do: query
  defp filter_status(query, status), do: where(query, status: ^status)

  def get_lead(%XAccount{} = account, id), do: Repo.get_by(Lead, id: id, x_account_id: account.id)

  def lead_counts(%XAccount{} = account) do
    counts =
      Lead
      |> where(x_account_id: ^account.id)
      |> group_by([l], l.status)
      |> select([l], {l.status, count(l.id)})
      |> Repo.all()
      |> Map.new()

    Map.put(counts, "all", counts |> Map.values() |> Enum.sum())
  end

  @doc """
  Inserts leads, keeping the better score when someone turns up twice.

  A person found by two watches is one lead. Replacing unconditionally
  would let a weak keyword match overwrite a strong follower match purely
  because it ran later.
  """
  def upsert_leads(attrs_list) when is_list(attrs_list) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    rows =
      attrs_list
      |> Enum.map(&build_row(&1, now))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq_by(&String.downcase(&1.handle))

    Repo.insert_all(Lead, rows,
      on_conflict:
        from(l in Lead,
          update: [
            set: [
              score: fragment("GREATEST(COALESCE(?, 0), EXCLUDED.score)", l.score),
              followers_count: fragment("EXCLUDED.followers_count"),
              bio: fragment("EXCLUDED.bio"),
              updated_at: fragment("EXCLUDED.updated_at")
            ]
          ]
        ),
      conflict_target: [:x_account_id, :handle]
    )
  end

  defp build_row(attrs, now) do
    case Lead.changeset(%Lead{}, attrs) do
      %{valid?: true} = changeset ->
        changeset
        |> Ecto.Changeset.apply_changes()
        |> Map.take([
          :x_account_id,
          :signal_agent_id,
          :x_user_id,
          :handle,
          :display_name,
          :avatar_url,
          :bio,
          :location,
          :followers_count,
          :following_count,
          :verified,
          :score,
          :reason,
          :source_post_id,
          :source_post_text,
          :status
        ])
        |> Map.merge(%{id: Ecto.UUID.generate(), inserted_at: now, updated_at: now})

      _ ->
        nil
    end
  end

  def update_lead(%Lead{} = lead, attrs) do
    lead |> Lead.changeset(attrs) |> Repo.update()
  end

  def set_lead_status(%Lead{} = lead, status) do
    attrs = %{status: status}

    attrs =
      if status == "contacted" and is_nil(lead.contacted_at),
        do: Map.put(attrs, :contacted_at, DateTime.utc_now() |> DateTime.truncate(:second)),
        else: attrs

    update_lead(lead, attrs)
  end

  @doc "Handles we already have, so a watch doesn't re-score known people."
  def known_handles(%XAccount{} = account) do
    Lead
    |> where(x_account_id: ^account.id)
    |> select([l], l.handle)
    |> Repo.all()
    |> MapSet.new(&String.downcase/1)
  end
end
