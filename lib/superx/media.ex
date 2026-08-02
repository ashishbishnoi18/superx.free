defmodule SuperX.Media do
  @moduledoc """
  Durable local media for posts waiting to publish.

  Segment maps keep opaque keys rather than absolute paths. That keeps the
  database portable across development, Docker and releases while one
  configurable directory remains the source of both browser previews and
  publish-time uploads to X.
  """

  import Ecto.Query

  alias SuperX.Accounts.{User, XAccount}
  alias SuperX.Content.Post
  alias SuperX.Media.Asset
  alias SuperX.Repo

  @max_file_size 5_000_000
  @key_pattern ~r/\A[0-9a-f-]{36}\.(gif|jpe?g|png|webp)\z/

  def max_file_size, do: @max_file_size

  def path do
    Application.get_env(:superx, __MODULE__, [])[:path] ||
      Application.app_dir(:superx, "priv/uploads")
  end

  @doc "Stores a completed LiveView upload under an explicit owner."
  def store_upload(
        %User{id: user_id},
        %XAccount{id: account_id, user_id: user_id},
        %{path: temporary_path}
      ) do
    with {:ok, %{size: size}} when size <= @max_file_size <- File.stat(temporary_path),
         {:ok, extension, _content_type} <- identify(temporary_path),
         :ok <- File.mkdir_p(path()) do
      key = "#{Ecto.UUID.generate()}.#{extension}"
      destination = Path.join(path(), key)

      case File.cp(temporary_path, destination) do
        :ok -> persist_asset(key, user_id, account_id, destination)
        {:error, reason} -> {:error, {:store_failed, reason}}
      end
    else
      {:ok, %{size: _size}} -> {:error, :too_large}
      {:error, reason} -> {:error, reason}
    end
  end

  def store_upload(%User{}, %XAccount{}, _meta), do: {:error, :account_mismatch}

  @doc "Resolves an owned local key to the file metadata needed by previews and X."
  def file(%User{id: user_id}, key) when is_binary(key) do
    resolve_owned_file(key, dynamic([asset], asset.user_id == ^user_id))
  end

  def file(%XAccount{id: account_id, user_id: user_id}, key) when is_binary(key) do
    resolve_owned_file(
      key,
      dynamic([asset], asset.user_id == ^user_id and asset.x_account_id == ^account_id)
    )
  end

  def file(%Post{user_id: user_id, x_account_id: account_id}, key) when is_binary(key) do
    resolve_owned_file(
      key,
      dynamic([asset], asset.user_id == ^user_id and asset.x_account_id == ^account_id)
    )
  end

  def file(_owner, _key), do: {:error, :not_found}

  @doc "Whether every key belongs to the named user and X account."
  def owned_by?(user_id, account_id, keys)
      when is_binary(user_id) and is_binary(account_id) and is_list(keys) do
    keys = Enum.uniq(keys)

    if Enum.all?(keys, &is_binary/1) do
      Asset
      |> where([asset], asset.key in ^keys)
      |> where([asset], asset.user_id == ^user_id and asset.x_account_id == ^account_id)
      |> select([asset], count(asset.id))
      |> Repo.one() == length(keys)
    else
      false
    end
  end

  def owned_by?(_user_id, _account_id, _keys), do: false

  defp resolve_owned_file(key, owner_filter) do
    owned? =
      Asset
      |> where([asset], asset.key == ^key)
      |> where(^owner_filter)
      |> Repo.exists?()

    if owned?, do: resolve_file(key), else: {:error, :not_found}
  end

  defp resolve_file(key) do
    with true <- Regex.match?(@key_pattern, key),
         path = Path.join(path(), key),
         {:ok, %{type: :regular, size: size}} <- File.stat(path),
         {:ok, extension, content_type} <- identify(path),
         true <- Path.extname(key) == ".#{extension}" do
      {:ok, %{path: path, filename: key, content_type: content_type, size: size}}
    else
      _ -> {:error, :not_found}
    end
  end

  def url(key), do: "/uploads/#{URI.encode(key)}"

  def gif?(key) when is_binary(key), do: Path.extname(key) == ".gif"
  def gif?(_key), do: false

  defp persist_asset(key, user_id, account_id, destination) do
    %Asset{user_id: user_id, x_account_id: account_id}
    |> Asset.changeset(%{key: key})
    |> Repo.insert()
    |> case do
      {:ok, _asset} ->
        {:ok, key}

      {:error, reason} ->
        _ = File.rm(destination)
        {:error, {:store_failed, reason}}
    end
  end

  defp identify(path) do
    with {:ok, header} <- read_header(path) do
      identify_header(header)
    end
  end

  defp read_header(path) do
    with {:ok, file} <- File.open(path, [:read, :binary]) do
      result = IO.binread(file, 12)
      File.close(file)

      case result do
        header when is_binary(header) -> {:ok, header}
        _ -> {:error, :unsupported_media}
      end
    end
  end

  defp identify_header(<<0xFF, 0xD8, 0xFF, _rest::binary>>),
    do: {:ok, "jpg", "image/jpeg"}

  defp identify_header(<<0x89, "PNG\r\n", 0x1A, "\n", _rest::binary>>),
    do: {:ok, "png", "image/png"}

  defp identify_header(<<"GIF87a", _rest::binary>>), do: {:ok, "gif", "image/gif"}
  defp identify_header(<<"GIF89a", _rest::binary>>), do: {:ok, "gif", "image/gif"}

  defp identify_header(<<"RIFF", _size::little-32, "WEBP", _rest::binary>>),
    do: {:ok, "webp", "image/webp"}

  defp identify_header(_header), do: {:error, :unsupported_media}
end
