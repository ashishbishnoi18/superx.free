defmodule SuperX.Mailer do
  use Swoosh.Mailer, otp_app: :superx

  @doc "Whether email leaves this instance rather than staying in the local preview."
  def configured? do
    adapter = Application.get_env(:superx, __MODULE__, [])[:adapter]
    not is_nil(adapter) and adapter != Swoosh.Adapters.Local
  end
end
