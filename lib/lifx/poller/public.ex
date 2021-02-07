defmodule Lifx.Poller do
  @moduledoc false

  alias Lifx.Device

  require Logger

  def schedule_device(pid, %Device{} = device) do
    Process.send_after(pid, {:poll_device, device}, 0)
  end

  @spec add_handler(pid()) :: :ok
  def add_handler(handler) do
    GenServer.call(__MODULE__, {:handler, handler})
  end
end
