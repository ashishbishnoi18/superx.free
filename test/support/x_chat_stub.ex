defmodule SuperX.XChatStub do
  @moduledoc false

  def available?, do: dispatch(:available, %{}, false)
  def register_keys, do: dispatch(:register_keys, %{}, {:error, :xchat_unavailable})

  def decrypt_events(params),
    do: dispatch(:decrypt_events, params, {:error, :xchat_unavailable})

  def encrypt_message(params),
    do: dispatch(:encrypt_message, params, {:error, :xchat_unavailable})

  defp dispatch(operation, params, default) do
    case Application.get_env(:superx, :xchat_stub_handler) do
      handler when is_function(handler, 2) -> handler.(operation, params)
      _missing -> default
    end
  end
end
