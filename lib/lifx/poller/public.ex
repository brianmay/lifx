defmodule Lifx.Poller do
  @moduledoc false

  alias Lifx.Device

  require Logger

  def poll_device(%Device{} = device) do
    GenServer.cast(__MODULE__, {:poll_device, device})
  end

  @spec add_handler(pid()) :: :ok
  def add_handler(handler) do
    GenServer.call(__MODULE__, {:handler, handler})
  end
end
