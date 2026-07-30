defmodule Mix.Tasks.Superx.Gen.VaultKey do
  @shortdoc "Generates a SUPERX_VAULT_KEY for encrypting stored OAuth tokens"

  @moduledoc """
  Prints a fresh 32-byte key, base64-encoded, for `SUPERX_VAULT_KEY`.

      $ mix superx.gen.vault_key

  Store it with the rest of your production secrets. Rotating it without
  re-encrypting existing rows will invalidate every stored X token and
  force all users to reconnect their accounts.
  """

  use Mix.Task

  @impl true
  def run(_args) do
    32 |> :crypto.strong_rand_bytes() |> Base.encode64() |> Mix.shell().info()
  end
end
