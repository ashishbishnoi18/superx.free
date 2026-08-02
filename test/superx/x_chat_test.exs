defmodule SuperX.XChatTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias SuperX.XChat

  test "a missing worker stays disabled at debug level" do
    previous_level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    missing =
      Path.join(System.tmp_dir!(), "missing-xchat-node-#{System.unique_integer([:positive])}")

    name = Module.concat(__MODULE__, "Worker#{System.unique_integer([:positive])}")

    log =
      capture_log([level: :debug], fn ->
        start_supervised!({XChat, name: name, binary: missing, script: missing <> ".mjs"})

        refute XChat.available?(name)
        assert {:error, :xchat_unavailable} = XChat.register_keys(name)
      end)

    assert log =~ "Optional XChat worker disabled"
    refute log =~ "warning"
  end
end
