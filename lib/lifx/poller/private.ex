defmodule Lifx.Poller.Private do
  @moduledoc false

  require Logger
  alias Lifx.Device

  def poll_device(%Device{} = device) do
    Logger.debug("Polling device #{device.id}.")

    case Device.get_label(device) do
      {:ok, _} ->
        Logger.debug("Polling #{device.id} succeeded.")
        :ok

      {:error, _} ->
        Logger.debug("Polling #{inspect(device)} failed.")
        Device.stop(device)
    end
  end
end
