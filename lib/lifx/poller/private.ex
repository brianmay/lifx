defmodule Lifx.Poller.Private do
  @moduledoc false

  require Logger
  alias Lifx.Device
  alias Lifx.Poller.Server.State

  defp get_poll_state_time, do: Application.get_env(:lifx, :poll_state_time)

  def schedule do
    time = get_poll_state_time()

    if time != :disable do
      {:ok, _} = :timer.send_interval(time, :poll_all)
    end
  end

  def poll_device(%State{} = state, %Device{} = device) do
    Logger.debug("Polling device #{device.id}.")

    with {:ok, location} <- Device.get_location(device),
         {:ok, label} <- Device.get_label(device),
         {:ok, group} <- Device.get_group(device) do
      device = %Device{device | location: location, label: label, group: group}
      notify(state, device, :polled)
    else
      {:error, error} -> Logger.debug("Got error #{error} polling #{device.id}.")
    end
  end

  def poll_device_list(%State{} = state, devices) do
    Logger.debug("Polling all devices.")

    Enum.each(devices, fn device ->
      poll_device(state, device)
    end)
  end

  @spec notify(State.t(), Device.t(), :polled) :: :ok
  def notify(%State{} = state, device, status) do
    Enum.each(state.handlers, fn handler ->
      GenServer.cast(handler, {status, device})
    end)
  end
end
