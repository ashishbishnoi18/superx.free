defmodule SuperX.VaultTest do
  use ExUnit.Case, async: true

  alias SuperX.Vault

  describe "encrypt/decrypt" do
    test "round-trips a value" do
      assert {:ok, "sensitive-token"} = "sensitive-token" |> Vault.encrypt() |> Vault.decrypt()
    end

    test "passes nil through so nullable columns work" do
      assert Vault.encrypt(nil) == nil
      assert Vault.decrypt(nil) == {:ok, nil}
    end

    test "produces different ciphertext for the same plaintext" do
      # A fresh IV each time; identical output would leak that two accounts
      # share a token.
      refute Vault.encrypt("same") == Vault.encrypt("same")
    end

    test "rejects tampered ciphertext" do
      <<version, iv::binary-12, tag::binary-16, ciphertext::binary>> = Vault.encrypt("token")

      flipped = :crypto.exor(ciphertext, :binary.copy(<<1>>, byte_size(ciphertext)))

      assert Vault.decrypt(<<version, iv::binary, tag::binary, flipped::binary>>) == :error
    end

    test "rejects a truncated payload" do
      assert Vault.decrypt(<<1, 2, 3>>) == :error
    end
  end

  describe "EncryptedBinary type" do
    alias SuperX.Vault.EncryptedBinary

    test "dumps to ciphertext and loads back to plaintext" do
      {:ok, dumped} = EncryptedBinary.dump("token")
      refute dumped == "token"
      assert {:ok, "token"} = EncryptedBinary.load(dumped)
    end

    test "loads undecryptable data as nil rather than crashing the query" do
      assert {:ok, nil} = EncryptedBinary.load(<<0, 0, 0>>)
    end
  end
end
