defmodule SuperXWeb.MediaUploads do
  @moduledoc """
  The shared LiveView upload contract for post attachments.

  A distinct upload configuration per segment makes X's four-image limit
  local to the post it governs, including when several thread segments or
  shelf drafts are editable on the same screen.
  """

  alias SuperX.Content.Post
  alias SuperX.Media

  @accept ~w(.gif .jpeg .jpg .png .webp)

  def allow(socket, name, existing_count) do
    if Map.has_key?(socket.assigns[:uploads] || %{}, name) do
      socket
    else
      # Video needs X's 512 MB asynchronous processing path. Keeping this
      # LiveView flow to 5 MB images and GIFs bounds memory, disk and worker
      # time without pretending a video is ready before X has processed it.
      Phoenix.LiveView.allow_upload(socket, name,
        accept: @accept,
        max_entries: max(Post.max_media_per_segment() - existing_count, 1),
        max_file_size: Media.max_file_size(),
        auto_upload: true
      )
    end
  end

  def consume(socket, name) do
    if in_progress?(socket, name) do
      {:error, :upload_in_progress}
    else
      results =
        Phoenix.LiveView.consume_uploaded_entries(socket, name, fn meta, _entry ->
          {:ok, Media.store_upload(meta)}
        end)

      case Enum.split_with(results, &match?({:ok, _key}, &1)) do
        {successful, []} -> {:ok, Enum.map(successful, fn {:ok, key} -> key end)}
        {_successful, [{:error, reason} | _]} -> {:error, reason}
      end
    end
  end

  def in_progress?(socket, name) do
    case Map.get(socket.assigns[:uploads] || %{}, name) do
      nil -> false
      upload -> Enum.any?(upload.entries, &(not &1.done?))
    end
  end

  def cancel(socket, name, ref) do
    if Map.has_key?(socket.assigns[:uploads] || %{}, name) do
      Phoenix.LiveView.cancel_upload(socket, name, ref)
    else
      socket
    end
  end
end
