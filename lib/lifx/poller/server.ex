defmodule Lifx.Poller.Server do
  @moduledoc false

  use GenServer

  alias Lifx.Poller.Private

  require Logger

  defmodule State do
    @moduledoc false
    @type t :: %__MODULE__{}
    defstruct []
  end

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: Lifx.Poller)
  end

  def init(:ok) do
    {:ok, %State{}}
  end

  def handle_cast({:poll_device, device}, state) do
    Private.poll_device(device)
    {:noreply, state}
  end
end
