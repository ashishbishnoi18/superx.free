defmodule Mix.Tasks.Superx.Gen.VaultKey do
  @shortdoc "Generates a SUPERX_VAULT_KEY for encrypting stored X secrets"

  @moduledoc """
  Prints a fresh 32-byte key, base64-encoded, for `SUPERX_VAULT_KEY`.

      $ mix superx.gen.vault_key

  Store it with the rest of your production secrets. Rotating it without
  re-encrypting existing rows will invalidate every stored X token and XChat
  identity. It forces all users to reconnect and can make encrypted chat
  history unreadable.
  """

  use Mix.Task

  @impl true
  def run(_args) do
    32 |> :crypto.strong_rand_bytes() |> Base.encode64() |> Mix.shell().info()
  end
end
