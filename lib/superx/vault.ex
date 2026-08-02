defmodule SuperX.Vault do
  @moduledoc """
  Symmetric encryption for X OAuth tokens and opaque XChat private-key blobs
  held at rest.

  AES-256-GCM via `:crypto`, so there is no extra dependency. The stored
  binary is `<<version, iv::96, tag::128, ciphertext::binary>>`; the
  version byte lets the key or cipher rotate later without a data
  migration.

  The key comes from `SUPERX_VAULT_KEY` (base64-encoded, 32 bytes). In
  dev and test it falls back to a key derived from the endpoint's
  `secret_key_base`, so a fresh checkout runs without extra setup. In
  production a missing key is fatal — see `config/runtime.exs`.
  """

  @version 1
  @aad "superx.vault.v1"

  @doc "Encrypts a binary. Returns `nil` for `nil` so it maps onto nullable columns."
  @spec encrypt(binary() | nil) :: binary() | nil
  def encrypt(nil), do: nil

  def encrypt(plaintext) when is_binary(plaintext) do
    iv = :crypto.strong_rand_bytes(12)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key(), iv, plaintext, @aad, true)

    <<@version, iv::binary-12, tag::binary-16, ciphertext::binary>>
  end

  @doc "Decrypts a binary produced by `encrypt/1`."
  @spec decrypt(binary() | nil) :: {:ok, binary() | nil} | :error
  def decrypt(nil), do: {:ok, nil}

  def decrypt(<<@version, iv::binary-12, tag::binary-16, ciphertext::binary>>) do
    case :crypto.crypto_one_time_aead(:aes_256_gcm, key(), iv, ciphertext, @aad, tag, false) do
      # A tag mismatch means tampering or the wrong key; both are :error.
      :error -> :error
      plaintext when is_binary(plaintext) -> {:ok, plaintext}
    end
  end

  def decrypt(_malformed), do: :error

  defp key do
    case Application.fetch_env(:superx, :vault_key) do
      {:ok, key} when byte_size(key) == 32 ->
        key

      _ ->
        raise """
        SuperX.Vault is missing a usable key.

        Set SUPERX_VAULT_KEY to 32 base64-encoded bytes:

            mix superx.gen.vault_key
        """
    end
  end
end
