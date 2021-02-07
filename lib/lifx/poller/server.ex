defmodule Lifx.Poller.Server do
  @moduledoc false

  use GenServer

  alias Lifx.Client
  alias Lifx.Poller.Private

  require Logger

  defmodule State do
    @moduledoc false
    @type t :: %__MODULE__{
            handlers: [pid()]
          }
    defstruct handlers: []
  end

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: Lifx.Poller)
  end

  def init(:ok) do
    Private.schedule()
    {:ok, %State{}}
  end

  def handle_info(:poll_all, state) do
    Private.poll_device_list(state, Client.devices())
    {:noreply, state}
  end

  def handle_info({:poll_device, device}, state) do
    Private.poll_device(state, device)
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    handlers = Enum.reject(state.handlers, fn handler -> handler == pid end)
    state = %State{state | handlers: handlers}
    {:noreply, state}
  end

  def handle_call({:handler, handler}, {_pid, _}, state) do
    _ref = Process.monitor(handler)
    {:reply, :ok, %State{state | handlers: [handler | state.handlers]}}
  end
end
