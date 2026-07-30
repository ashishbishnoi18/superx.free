defmodule SuperX.Accounts.OAuthRequest do
  @moduledoc """
  One in-flight OAuth2 PKCE handshake.

  The `state` is echoed by X and proves the callback belongs to a request
  we started; the `code_verifier` is the PKCE secret exchanged for tokens.
  Rows are single-use and expire after ten minutes.
  """

  use SuperX.Schema

  import Ecto.Changeset

  @ttl_seconds 600

  @derive {Inspect, except: [:code_verifier]}
  schema "oauth_requests" do
    field :state, :string
    field :code_verifier, :string
    field :redirect_to, :string
    field :expires_at, :utc_datetime

    belongs_to :user, SuperX.Accounts.User

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc """
  Builds a handshake. Pass `user_id` when an already-signed-in user is
  connecting an additional account rather than logging in.
  """
  def build(attrs \\ %{}) do
    state = random_string()
    verifier = random_string()

    expires_at =
      DateTime.utc_now() |> DateTime.add(@ttl_seconds, :second) |> DateTime.truncate(:second)

    %__MODULE__{
      state: state,
      code_verifier: verifier,
      user_id: attrs[:user_id],
      redirect_to: attrs[:redirect_to],
      expires_at: expires_at
    }
  end

  @doc """
  The S256 PKCE challenge derived from a verifier.
  """
  def challenge(verifier) when is_binary(verifier) do
    :sha256
    |> :crypto.hash(verifier)
    |> Base.url_encode64(padding: false)
  end

  @doc false
  def changeset(request, attrs) do
    request
    |> cast(attrs, [:state, :code_verifier, :redirect_to, :expires_at, :user_id])
    |> validate_required([:state, :code_verifier, :expires_at])
    |> unique_constraint(:state)
  end

  defp random_string, do: 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
end
