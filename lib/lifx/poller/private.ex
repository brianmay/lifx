defmodule Lifx.Poller.Private do
  @moduledoc false

  require Logger
  alias Lifx.Device

  defp get_poll_state_time, do: Application.get_env(:lifx, :poll_state_time)

  def reschedule do
    time = get_poll_state_time()

    if time != :disable do
      Process.send_after(self(), :poll_all, time)
    end
  end

  def poll_device(%Device{} = device) do
    Logger.debug("Polling device #{device.id}.")

    with {:ok, _} <- Device.get_location(device),
         {:ok, _} <- Device.get_label(device),
         {:ok, _} <- Device.get_group(device) do
      nil
    else
      {:error, error} -> Logger.debug("Got error #{error} polling #{device.id}.")
    end
  end

  def poll_device_list(devices) do
    Logger.debug("Polling all devices.")

    Enum.each(devices, fn device ->
      poll_device(device)
    end)
  end
end
