defmodule SuperX.Accounts.User do
  @moduledoc """
  The billing and login entity. A user may drive several connected X
  accounts and always has exactly one selected as the default.
  """

  use SuperX.Schema

  import Ecto.Changeset

  alias SuperX.Accounts.{ApiToken, XAccount}

  @derive {Inspect, except: [:email]}
  schema "users" do
    field :email, :string
    field :name, :string
    field :avatar_url, :string
    field :timezone, :string, default: "Etc/UTC"

    field :settings, :map, default: %{}

    field :onboarding_completed_at, :utc_datetime

    belongs_to :default_x_account, XAccount
    belongs_to :team_owner, __MODULE__
    has_many :x_accounts, XAccount, preload_order: [asc: :inserted_at]
    has_many :api_tokens, ApiToken
    has_many :content_workers, SuperX.Workers.ContentWorker
    has_many :team_members, __MODULE__, foreign_key: :team_owner_id
    has_many :team_invitations, SuperX.Teams.Invitation, foreign_key: :owner_id

    has_one :subscription, SuperX.Billing.Subscription

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(user, attrs) do
    user
    |> cast(attrs, [
      :email,
      :name,
      :avatar_url,
      :timezone,
      :settings,
      :onboarding_completed_at,
      :default_x_account_id
    ])
    |> validate_length(:name, max: 120)
    |> validate_timezone()
    |> unique_constraint(:email)
  end

  defp validate_timezone(changeset) do
    validate_change(changeset, :timezone, fn :timezone, tz ->
      case DateTime.now(tz) do
        {:ok, _} -> []
        _ -> [timezone: "is not a known time zone"]
      end
    end)
  end

  @doc """
  Default UI settings for a new user, mirroring the shape the app reads
  on every page load.
  """
  def default_settings do
    %{
      "theme" => "light",
      # How many of each content type to keep on the Ready to Post shelf.
      "daily_mix" => %{"for_you" => 6, "trending" => 3, "viral" => 3, "products" => 0}
    }
  end
end
