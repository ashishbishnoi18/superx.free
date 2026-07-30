defmodule SuperX.Workers.QuotaRoller do
  @moduledoc """
  Rolls expired quota windows.

  Windows also roll lazily whenever a quota is read, so this job is a
  safety net rather than the mechanism — it keeps the numbers a user sees
  on the upgrade page correct even if they haven't touched a metered
  feature since the window closed.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 3

  import Ecto.Query

  alias SuperX.Accounts.User
  alias SuperX.{Billing, Repo}
  alias SuperX.Billing.Quota

  @impl Oban.Worker
  def perform(_job) do
    now = DateTime.utc_now()

    user_ids =
      Quota
      |> where([q], q.window_end <= ^now)
      |> select([q], q.user_id)
      |> distinct(true)
      |> Repo.all()

    User
    |> where([u], u.id in ^user_ids)
    |> Repo.all()
    |> Enum.each(fn user ->
      Enum.each(Quota.keys(), &Billing.get_quota(user, &1))
    end)

    :ok
  end
end
