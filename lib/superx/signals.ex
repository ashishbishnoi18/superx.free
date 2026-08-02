defmodule SuperX.Signals do
  @moduledoc """
  Watch agents and the leads they find.
  """

  import Ecto.Query

  alias SuperX.Accounts.XAccount
  alias SuperX.Repo
  alias SuperX.Signals.{Agent, ContactList, ContactListMembership, ContactListShare, Lead}

  @engage_statuses ~w(contacted replied)

  # --- Agents --------------------------------------------------------------

  def list_agents(%XAccount{} = account) do
    Agent
    |> where(x_account_id: ^account.id)
    |> order_by(asc: :inserted_at)
    |> preload(:contact_list)
    |> Repo.all()
  end

  def get_agent(%XAccount{} = account, id),
    do: Repo.get_by(Agent, id: id, x_account_id: account.id)

  def create_agent(%XAccount{} = account, attrs) do
    changeset = Agent.changeset(%Agent{}, Map.put(attrs, :x_account_id, account.id))

    case filing_list(account, attrs[:contact_list_id] || attrs["contact_list_id"]) do
      %ContactList{} = list ->
        changeset
        |> Ecto.Changeset.put_change(:contact_list_id, list.id)
        |> Repo.insert()

      nil ->
        {:error, Ecto.Changeset.add_error(changeset, :contact_list_id, "is not available")}
    end
  end

  def update_agent(%Agent{} = agent, attrs) do
    changeset = Agent.changeset(agent, attrs)
    contact_list_id = attrs[:contact_list_id] || attrs["contact_list_id"]

    if is_nil(contact_list_id) or filing_list(agent.x_account_id, contact_list_id) do
      Repo.update(changeset)
    else
      {:error, Ecto.Changeset.add_error(changeset, :contact_list_id, "is not available")}
    end
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
    account
    |> lead_query(opts[:list])
    |> filter_status(opts[:status])
    |> order_by([l], desc: fragment("coalesce(?, 0)", l.score), desc: l.inserted_at)
    |> maybe_limit(Keyword.get(opts, :limit, 100))
    |> preload(:signal_agent)
    |> Repo.all()
  end

  defp maybe_limit(query, nil), do: query
  defp maybe_limit(query, limit), do: limit(query, ^limit)

  defp filter_status(query, nil), do: query
  defp filter_status(query, status), do: where(query, status: ^status)

  def get_lead(%XAccount{} = account, id), do: Repo.get_by(Lead, id: id, x_account_id: account.id)

  def lead_counts(%XAccount{} = account, opts \\ []) do
    counts =
      account
      |> lead_query(opts[:list])
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

    case rows do
      [] ->
        {0, nil}

      rows ->
        {:ok, result} =
          Repo.transaction(fn ->
            result =
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

            file_leads(rows, now)
            result
          end)

        result
    end
  end

  defp file_leads(rows, now) do
    agent_ids = rows |> Enum.map(& &1.signal_agent_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    targets =
      Agent
      |> where([a], a.id in ^agent_ids and not is_nil(a.contact_list_id))
      |> select([a], {a.id, {a.x_account_id, a.contact_list_id}})
      |> Repo.all()
      |> Map.new()

    incoming =
      Map.new(rows, fn row ->
        {{row.x_account_id, String.downcase(row.handle)}, row.signal_agent_id}
      end)

    account_ids = rows |> Enum.map(& &1.x_account_id) |> Enum.uniq()
    handles = rows |> Enum.map(&String.downcase(&1.handle)) |> Enum.uniq()

    memberships =
      Lead
      |> where([l], l.x_account_id in ^account_ids)
      |> where([l], fragment("lower(?)", l.handle) in ^handles)
      |> select([l], {l.id, l.x_account_id, l.handle})
      |> Repo.all()
      |> Enum.flat_map(fn {lead_id, account_id, handle} ->
        with agent_id when not is_nil(agent_id) <-
               Map.get(incoming, {account_id, String.downcase(handle)}),
             {^account_id, contact_list_id} <- Map.get(targets, agent_id) do
          [
            %{
              contact_list_id: contact_list_id,
              lead_id: lead_id,
              inserted_at: now,
              updated_at: now
            }
          ]
        else
          _ -> []
        end
      end)

    Repo.insert_all(ContactListMembership, memberships,
      on_conflict: :nothing,
      conflict_target: [:contact_list_id, :lead_id]
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

  @doc "Files previously known matches without re-scoring or changing their CRM state."
  def file_known_leads(%Agent{contact_list_id: nil}, _candidates), do: 0

  def file_known_leads(%Agent{} = agent, candidates) when is_list(candidates) do
    handles =
      candidates
      |> Enum.map(& &1[:handle])
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&String.downcase/1)
      |> Enum.uniq()

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    memberships =
      Lead
      |> where([l], l.x_account_id == ^agent.x_account_id)
      |> where([l], fragment("lower(?)", l.handle) in ^handles)
      |> select([l], l.id)
      |> Repo.all()
      |> Enum.map(fn lead_id ->
        %{
          contact_list_id: agent.contact_list_id,
          lead_id: lead_id,
          inserted_at: now,
          updated_at: now
        }
      end)

    {count, _rows} =
      Repo.insert_all(ContactListMembership, memberships,
        on_conflict: :nothing,
        conflict_target: [:contact_list_id, :lead_id]
      )

    count
  end

  # --- Contact lists -------------------------------------------------------

  @doc "The account's saved audiences, with the two built-in contracts first."
  def list_contact_lists(%XAccount{} = account) do
    ensure_contact_lists(account)

    ContactList
    |> where(x_account_id: ^account.id)
    |> order_by([l],
      asc:
        fragment(
          "CASE ? WHEN 'followers' THEN 0 WHEN 'engage' THEN 1 ELSE 2 END",
          l.kind
        ),
      asc: l.name
    )
    |> Repo.all()
  end

  def manual_contact_lists(%XAccount{} = account) do
    account
    |> list_contact_lists()
    |> Enum.filter(&ContactList.editable?/1)
  end

  def get_contact_list(%XAccount{} = account, id) when is_binary(id),
    do: Repo.get_by(ContactList, id: id, x_account_id: account.id)

  def get_contact_list(%XAccount{}, _id), do: nil

  def create_contact_list(%XAccount{} = account, attrs) do
    ensure_contact_lists(account)

    %ContactList{x_account_id: account.id, kind: "manual"}
    |> ContactList.changeset(attrs)
    |> Repo.insert()
  end

  def delete_contact_list(%XAccount{} = account, id) do
    with %ContactList{} = list <- get_contact_list(account, id),
         true <- ContactList.deletable?(list) do
      followers = filing_list(account, nil)

      Repo.transaction(fn ->
        Agent
        |> where([a], a.x_account_id == ^account.id and a.contact_list_id == ^list.id)
        |> Repo.update_all(set: [contact_list_id: followers.id])

        Repo.delete!(list)
      end)
    else
      nil -> {:error, :not_found}
      false -> {:error, :protected}
    end
  end

  def contact_list_counts(%XAccount{} = account) do
    stored =
      ContactList
      |> where([l], l.x_account_id == ^account.id)
      |> join(:left, [l], m in ContactListMembership, on: m.contact_list_id == l.id)
      |> group_by([l], l.id)
      |> select([l, m], {l.id, count(m.lead_id)})
      |> Repo.all()
      |> Map.new()

    engage_count =
      Lead
      |> where([l], l.x_account_id == ^account.id and l.status in ^@engage_statuses)
      |> Repo.aggregate(:count, :id)

    account
    |> list_contact_lists()
    |> Enum.reduce(stored, fn
      %ContactList{kind: "engage", id: id}, counts -> Map.put(counts, id, engage_count)
      _list, counts -> counts
    end)
  end

  @doc "Adds or removes one contact from an editable list."
  def toggle_contact_list_membership(%XAccount{} = account, lead_id, contact_list_id) do
    with %Lead{} = lead <- get_lead(account, lead_id),
         %ContactList{} = list <- get_contact_list(account, contact_list_id),
         true <- ContactList.editable?(list) do
      case Repo.get_by(ContactListMembership, contact_list_id: list.id, lead_id: lead.id) do
        nil ->
          %ContactListMembership{contact_list_id: list.id, lead_id: lead.id}
          |> Repo.insert()
          |> then(fn {:ok, _membership} -> {:ok, :added} end)

        membership ->
          Repo.delete(membership)
          |> then(fn {:ok, _membership} -> {:ok, :removed} end)
      end
    else
      nil -> {:error, :not_found}
      false -> {:error, :derived}
    end
  end

  def contact_list_ids_for_leads(%XAccount{} = account, lead_ids) do
    ContactListMembership
    |> join(:inner, [m], l in Lead, on: l.id == m.lead_id)
    |> where([m, l], l.x_account_id == ^account.id and m.lead_id in ^lead_ids)
    |> select([m], {m.lead_id, m.contact_list_id})
    |> Repo.all()
    |> Enum.reduce(%{}, fn {lead_id, list_id}, memberships ->
      Map.update(memberships, lead_id, MapSet.new([list_id]), &MapSet.put(&1, list_id))
    end)
  end

  defp ensure_contact_lists(%XAccount{} = account) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    rows = [
      default_list_row(account, "Followers", "followers", now),
      default_list_row(account, "Engage", "engage", now)
    ]

    Repo.insert_all(ContactList, rows,
      on_conflict: :nothing,
      conflict_target: {:unsafe_fragment, "(x_account_id, kind) WHERE kind <> 'manual'"}
    )

    :ok
  end

  defp default_list_row(account, name, kind, now) do
    %{
      id: Ecto.UUID.generate(),
      x_account_id: account.id,
      name: name,
      kind: kind,
      inserted_at: now,
      updated_at: now
    }
  end

  defp filing_list(%XAccount{} = account, id), do: filing_list(account.id, id)

  defp filing_list(account_id, id) when id in [nil, ""] do
    account = %XAccount{id: account_id}
    ensure_contact_lists(account)
    Repo.get_by(ContactList, x_account_id: account_id, kind: "followers")
  end

  defp filing_list(account_id, id) do
    ContactList
    |> where([l], l.id == ^id and l.x_account_id == ^account_id)
    |> where([l], l.kind in ["manual", "followers"])
    |> Repo.one()
  end

  defp lead_query(%XAccount{} = account, list), do: lead_query(account.id, list)

  defp lead_query(account_id, nil), do: where(Lead, x_account_id: ^account_id)

  defp lead_query(account_id, %ContactList{x_account_id: account_id, kind: "engage"}) do
    Lead
    |> where([l], l.x_account_id == ^account_id and l.status in ^@engage_statuses)
  end

  defp lead_query(account_id, %ContactList{x_account_id: account_id, id: list_id}) do
    Lead
    |> where([l], l.x_account_id == ^account_id)
    |> join(:inner, [l], m in ContactListMembership,
      on: m.lead_id == l.id and m.contact_list_id == ^list_id,
      as: :membership
    )
  end

  defp lead_query(account_id, %ContactList{}) do
    Lead |> where([l], l.x_account_id == ^account_id and false)
  end

  # --- Export --------------------------------------------------------------

  @doc "A database stream for CSV export; consume it inside a Repo transaction."
  def stream_contact_export(%XAccount{} = account, list \\ nil) do
    account
    |> lead_query(list)
    |> join(:left, [l], a in Agent, on: a.id == l.signal_agent_id, as: :agent)
    |> order_by([l], asc: l.handle)
    |> select([l, agent: a], %{
      display_name: l.display_name,
      handle: l.handle,
      bio: l.bio,
      location: l.location,
      followers_count: l.followers_count,
      following_count: l.following_count,
      verified: l.verified,
      score: l.score,
      reason: l.reason,
      status: l.status,
      notes: l.notes,
      contacted_at: l.contacted_at,
      agent_name: a.name,
      source_post_id: l.source_post_id
    })
    |> Repo.stream(max_rows: 500)
  end

  # --- Public contact lists ------------------------------------------------

  @doc "Creates or replaces a list's public view with a fresh capability URL."
  def create_contact_list_share(%XAccount{} = account, %ContactList{} = candidate) do
    with %ContactList{} = list <- get_contact_list(account, candidate.id) do
      attrs = %{token: share_token(), revoked_at: nil}

      case Repo.get_by(ContactListShare, contact_list_id: list.id) do
        nil ->
          %ContactListShare{contact_list_id: list.id}
          |> ContactListShare.changeset(attrs)
          |> Repo.insert()

        share ->
          share |> ContactListShare.changeset(attrs) |> Repo.update()
      end
    else
      nil -> {:error, :not_found}
    end
  end

  def get_contact_list_share(%XAccount{} = account, %ContactList{} = list) do
    ContactListShare
    |> join(:inner, [s], l in ContactList, on: l.id == s.contact_list_id)
    |> where(
      [s, l],
      l.id == ^list.id and l.x_account_id == ^account.id and is_nil(s.revoked_at)
    )
    |> select([s], s)
    |> Repo.one()
  end

  @doc "Revokes a list's public view without making its old token reusable."
  def revoke_contact_list_share(%XAccount{} = account, %ContactList{} = list) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    ContactListShare
    |> join(:inner, [s], l in ContactList, on: l.id == s.contact_list_id)
    |> where(
      [s, l],
      l.id == ^list.id and l.x_account_id == ^account.id and is_nil(s.revoked_at)
    )
    |> Repo.update_all(set: [revoked_at: now, updated_at: now])

    :ok
  end

  @doc "Looks up the narrow, paged payload exposed by a contact-list capability."
  def public_contact_list_share(token, opts \\ []) when is_binary(token) do
    page = max(opts[:page] || 1, 1)
    per_page = 100

    ContactListShare
    |> where([s], s.token == ^token and is_nil(s.revoked_at))
    |> preload(contact_list: :x_account)
    |> Repo.one()
    |> case do
      nil -> nil
      share -> public_contact_list_payload(share, page, per_page)
    end
  end

  defp public_contact_list_payload(%ContactListShare{} = share, page, per_page) do
    list = share.contact_list
    account = list.x_account
    query = lead_query(account.id, list)
    count = Repo.aggregate(query, :count, :id)
    pages = max(div(count + per_page - 1, per_page), 1)
    page = min(page, pages)

    contacts =
      query
      |> order_by([l], asc: l.handle)
      |> limit(^per_page)
      |> offset(^((page - 1) * per_page))
      # Names, handles, bios, reach and verification are already public on
      # X. Notes, qualification reasoning, source watches, workflow state,
      # location and internal identifiers reveal the owner's private research
      # and outreach, so a bearer of the capability never receives them.
      |> select([l], %{
        display_name: l.display_name,
        handle: l.handle,
        bio: l.bio,
        followers_count: l.followers_count,
        verified: l.verified
      })
      |> Repo.all()

    %{
      account: %{display_name: account.display_name, handle: account.handle},
      list: %{name: list.name, derived?: ContactList.derived?(list)},
      contacts: contacts,
      count: count,
      page: page,
      pages: pages
    }
  end

  defp share_token do
    32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end
end
