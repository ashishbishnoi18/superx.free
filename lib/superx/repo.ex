defmodule SuperX.Repo do
  use Ecto.Repo,
    otp_app: :superx,
    adapter: Ecto.Adapters.Postgres
end
