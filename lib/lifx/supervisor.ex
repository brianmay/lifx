defmodule Lifx.Supervisor do
  @moduledoc false

  use Supervisor
  require Logger

  def start_link do
    Supervisor.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  def init(:ok) do
    children = [
      worker(Lifx.Client.Server, []),
      worker(Lifx.Poller.Server, [[name: Lifx.Poller]]),
      supervisor(Lifx.DeviceSupervisor, [])
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
