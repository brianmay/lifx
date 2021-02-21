defmodule Lifx.Client.Server do
  @moduledoc false

  use GenServer
  use Lifx.Protocol.Types

  require Logger

  alias Lifx.Device
  alias Lifx.Protocol
  alias Lifx.Protocol.{FrameAddress, FrameHeader, ProtocolHeader}
  alias Lifx.Protocol.Packet

  @port 56_700
  defp get_multicast, do: Application.get_env(:lifx, :multicast)
  defp get_poll_discover_time, do: Application.get_env(:lifx, :poll_discover_time)
  defp get_udp, do: Application.get_env(:lifx, :udp)

  defmodule State do
    @moduledoc false
    @type t :: %__MODULE__{
            udp: port(),
            source: integer(),
            handlers: [pid()],
            devices: [Device.t()]
          }
    defstruct udp: nil,
              source: 0,
              handlers: [],
              devices: []
  end

  @spec start_link() :: {:ok, pid()}
  def start_link do
    GenServer.start_link(__MODULE__, :ok, name: Lifx.Client)
  end

  @spec init(:ok) :: {:ok, State.t()}
  def init(:ok) do
    source = :rand.uniform(4_294_967_295)
    Logger.debug("LIFX Client: #{source}")

    udp_options = [
      :binary,
      {:broadcast, true},
      {:ip, {0, 0, 0, 0}},
      {:reuseaddr, true}
    ]

    {:ok, udp} = get_udp().open(0, udp_options)
    Process.send_after(self(), :discover, 1)
    :timer.send_interval(get_poll_discover_time(), :discover)

    {:ok, %State{source: source, udp: udp}}
  end

  def handle_call(:discover, _from, state) do
    Logger.debug("Running discover on demand.")
    send_discovery_packet(state.source, state.udp)
    {:reply, :ok, state}
  end

  def handle_call({:handler, handler}, {_pid, _}, state) do
    _ref = Process.monitor(handler)
    {:reply, :ok, %State{state | handlers: [handler | state.handlers]}}
  end

  def handle_call(:devices, _from, state) do
    {:reply, state.devices, state}
  end

  def handle_info(:discover, state) do
    Logger.debug("Running discover on timer.")
    send_discovery_packet(state.source, state.udp)
    {:noreply, state}
  end

  def handle_info({:udp, _s, ip, _port, payload}, state) do
    state = process(ip, payload, state)
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {pid_devices, other_devices} =
      Enum.split_with(state.devices, fn device -> device.pid == pid end)

    handlers = Enum.reject(state.handlers, fn handler -> handler == pid end)
    state = %State{state | devices: other_devices, handlers: handlers}

    Enum.each(pid_devices, fn device -> notify(state, device, :deleted) end)
    {:noreply, state}
  end

  @spec lookup_device(atom(), State.t()) :: Device.t() | nil
  defp lookup_device(target, state) do
    device_list =
      state.devices
      |> Enum.filter(fn device -> device.id == target end)
      |> Enum.take(-1)

    case device_list do
      [device] -> device
      [] -> nil
    end
  end

  @spec update_device(Device.t(), State.t()) :: State.t()

  defp update_device(%Device{} = device, %State{} = state) do
    if lookup_device(device.id, state) == nil do
      notify(state, device, :added)
    else
      notify(state, device, :updated)
    end

    devices =
      if Enum.any?(state.devices, fn dev -> dev.id == device.id end) do
        Enum.map(state.devices, fn d ->
          if device.id == d.id do
            device
          else
            d
          end
        end)
      else
        [device | state.devices]
      end

    %State{state | :devices => devices}
  end

  @spec dispatch_packet(Device.t(), Packet.t(), State.t()) :: State.t()

  defp dispatch_packet(%Device{} = device, %Packet{} = packet, %State{} = state) do
    case Device.packet(device, packet) do
      :ok -> nil
      {:error, err} -> Logger.debug("Cannot contact #{device.id}: #{err}.")
    end

    state
  end

  @spec update_device_from_packet(Device.t(), Packet.t(), State.t()) :: State.t()
  defp update_device_from_packet(
         %Device{} = device,
         %Packet{:protocol_header => %ProtocolHeader{:type => @statelabel}} = packet,
         state
       ) do
    %Device{device | label: packet.payload.label}
    |> update_device(state)
  end

  defp update_device_from_packet(
         %Device{} = device,
         %Packet{:protocol_header => %ProtocolHeader{:type => @stategroup}} = packet,
         state
       ) do
    %Device{device | group: packet.payload.group}
    |> update_device(state)
  end

  defp update_device_from_packet(
         %Device{} = device,
         %Packet{:protocol_header => %ProtocolHeader{:type => @statelocation}} = packet,
         state
       ) do
    %Device{device | location: packet.payload.location}
    |> update_device(state)
  end

  defp update_device_from_packet(_device, _packet, state) do
    state
  end

  @spec handle_packet(Packet.t(), tuple(), State.t()) :: State.t()

  defp handle_packet(
         %Packet{:protocol_header => %ProtocolHeader{:type => @stateservice}} = packet,
         ip,
         state
       ) do
    target = packet.frame_address.target
    host = ip
    port = packet.payload.port

    device =
      case lookup_device(target, state) do
        nil ->
          device = %Device{
            id: target,
            pid: nil,
            host: host,
            port: port
          }

          result =
            Lifx.DeviceSupervisor.start_device(
              device,
              state.udp,
              state.source
            )

          case result do
            {:ok, child} ->
              _ref = Process.monitor(child)
              device = %Device{device | pid: child}
              Lifx.Poller.schedule_device(Lifx.Poller, device)
              device

            {:error, error} ->
              Logger.error("Cannot start device child process for #{target}: #{inspect(error)}.")

              nil
          end

        device ->
          %Device{device | host: host, port: port}
      end

    case device do
      nil -> state
      device -> update_device(device, state)
    end
  end

  defp handle_packet(%Packet{:frame_address => %FrameAddress{:target => :all}}, _ip, state) do
    state
  end

  defp handle_packet(
         %Packet{:frame_address => %FrameAddress{:target => target}} = packet,
         _ip,
         state
       ) do
    case lookup_device(target, state) do
      nil ->
        Logger.debug("Cannot find device #{target}.")
        state

      device ->
        state = update_device_from_packet(device, packet, state)
        dispatch_packet(device, packet, state)
    end
  end

  @spec process(tuple(), bitstring(), State.t()) :: State.t()
  defp process(ip, payload, state) do
    payload
    |> Protocol.parse_packet()
    |> handle_packet(ip, state)
  end

  @spec send_discovery_packet(integer(), port()) :: :ok | {:error, atom()}
  defp send_discovery_packet(source, udp) do
    get_udp().send(
      udp,
      get_multicast(),
      @port,
      %Packet{
        :frame_header => %FrameHeader{:source => source, :tagged => 1},
        :frame_address => %FrameAddress{:res_required => 1},
        :protocol_header => %ProtocolHeader{:type => @getservice}
      }
      |> Protocol.create_packet()
    )
  end

  @spec notify(State.t(), Device.t(), :added | :updated | :deleted) :: :ok
  defp notify(%State{} = state, %Device{} = device, status) do
    Enum.each(state.handlers, fn handler ->
      GenServer.cast(handler, {status, device})
    end)
  end
end
