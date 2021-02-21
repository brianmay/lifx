defmodule Lifx.Device.Server do
  @moduledoc false

  use GenServer, restart: :transient
  use Lifx.Protocol.Types
  require Logger
  alias Lifx.Device
  alias Lifx.Poller
  alias Lifx.Protocol
  alias Lifx.Protocol.{FrameAddress, FrameHeader, ProtocolHeader}
  alias Lifx.Protocol.{Group, Location}
  alias Lifx.Protocol.Packet

  defp get_udp, do: Application.get_env(:lifx, :udp)
  defp get_dead_time, do: Application.get_env(:lifx, :dead_time)
  defp get_max_retries, do: Application.get_env(:lifx, :max_retries)
  defp get_wait_between_retry, do: Application.get_env(:lifx, :wait_between_retry)

  defmodule Pending do
    @moduledoc false
    @type t :: %__MODULE__{
            packet: Packet.t(),
            payload: bitstring(),
            from: GenServer.server(),
            tries: integer(),
            timer: pid(),
            mode: :forget | :retry | :response
          }
    @enforce_keys [:packet, :payload, :from, :tries, :timer, :mode]
    defstruct packet: nil, payload: nil, from: nil, tries: 0, timer: nil, mode: nil
  end

  defmodule State do
    @moduledoc false
    @type t :: %__MODULE__{
            device: Device.t(),
            udp: port(),
            source: integer(),
            sequence: integer(),
            pending_list: %{required(integer()) => Pending.t()},
            dead_timer: reference()
          }

    @enforce_keys [:device, :udp, :source, :dead_timer]
    defstruct device: nil,
              host: {0, 0, 0, 0},
              label: nil,
              group: %Group{},
              location: %Location{},
              udp: nil,
              source: 0,
              sequence: 0,
              pending_list: %{},
              dead_timer: nil
  end

  @spec prefix(State.t()) :: String.t()
  defp prefix(state) do
    "Device #{state.device.id}:"
  end

  @spec start_link({Device.t(), port(), integer()}) :: {:ok, pid()}
  def start_link({%Device{} = device, udp, source}) do
    GenServer.start_link(Lifx.Device.Server, {device, udp, source})
  end

  @spec init({Device.t(), port(), integer()}) :: {:ok, State.t()}
  def init({device, udp, source}) do
    dead_timer = Process.send_after(self(), :dead, get_dead_time())

    device = %Device{device | pid: self()}

    state = %State{
      device: device,
      udp: udp,
      source: source,
      dead_timer: dead_timer
    }

    {:ok, state}
  end

  @spec handle_packet(Packet.t(), State.t()) :: State.t()
  defp handle_packet(
         %Packet{:protocol_header => %ProtocolHeader{:type => @statelabel}} = packet,
         state
       ) do
    device = %Device{state.device | label: packet.payload.label}
    %State{state | device: device}
  end

  defp handle_packet(
         %Packet{:protocol_header => %ProtocolHeader{:type => @stategroup}} = packet,
         state
       ) do
    device = %Device{state.device | group: packet.payload.group}
    %State{state | device: device}
  end

  defp handle_packet(
         %Packet{:protocol_header => %ProtocolHeader{:type => @statelocation}} = packet,
         state
       ) do
    device = %Device{state.device | location: packet.payload.location}
    %State{state | device: device}
  end

  defp handle_packet(_packet, state) do
    state
  end

  def handle_call({:packet, %Packet{} = packet}, _from, state) do
    Logger.debug("#{prefix(state)} Received packet.")
    Process.cancel_timer(state.dead_timer)
    dead_timer = Process.send_after(self(), :dead, get_dead_time())
    state = %State{state | dead_timer: dead_timer}

    state = handle_packet(packet, state)
    sequence = packet.frame_address.sequence

    state =
      if Map.has_key?(state.pending_list, sequence) do
        pending = state.pending_list[sequence]
        Process.cancel_timer(pending.timer)

        if is_nil(pending.from) do
          Logger.debug("#{prefix(state)} Got seq #{sequence}, not alerting sender.")
        else
          Logger.debug("#{prefix(state)} Got seq #{sequence}, alerting sender.")
          GenServer.reply(pending.from, {:ok, packet.payload})
        end

        Map.update(state, :pending_list, nil, &Map.delete(&1, sequence))
      else
        Logger.debug("#{prefix(state)} Got seq #{sequence}, no record, presumed already done.")
        state
      end

    {:reply, :ok, state}
  end

  def handle_call({:send, protocol_type, payload, mode}, from, state) do
    {res_required, ack_required} =
      case mode do
        :response -> {1, 0}
        :retry -> {0, 1}
      end

    packet = %Packet{
      :frame_header => %FrameHeader{},
      :frame_address => %FrameAddress{
        target: state.device.id,
        res_required: res_required,
        ack_required: ack_required
      },
      :protocol_header => %ProtocolHeader{type: protocol_type}
    }

    state = schedule_packet(state, packet, payload, from, mode)
    {:noreply, state}
  end

  def handle_cast(:update, state) do
    Logger.debug("#{prefix(state)} Received update.")
    Process.cancel_timer(state.dead_timer)
    dead_timer = Process.send_after(self(), :dead, get_dead_time())
    state = %State{state | dead_timer: dead_timer}
    {:noreply, state}
  end

  def handle_cast(:stop, state) do
    Logger.info("#{prefix(state)} Received stop.")
    {:stop, :normal, state}
  end

  def handle_cast({:send, protocol_type, payload, mode}, state) do
    ack_required =
      case mode do
        :forget -> 0
        :retry -> 1
      end

    packet = %Packet{
      :frame_header => %FrameHeader{},
      :frame_address => %FrameAddress{target: state.device.id, ack_required: ack_required},
      :protocol_header => %ProtocolHeader{type: protocol_type}
    }

    state = schedule_packet(state, packet, payload, nil, mode)
    {:noreply, state}
  end

  @spec schedule_packet(
          State.t(),
          Packet.t(),
          bitstring(),
          GenServer.server(),
          :forget | :retry | :response
        ) :: State.t()
  defp schedule_packet(state, packet, payload, from, mode) do
    sequence = state.sequence
    Logger.debug("#{prefix(state)} Scheduling seq #{sequence}.")

    packet = put_in(packet.frame_address.sequence, sequence)

    timer = Process.send_after(self(), {:send, sequence}, 0)

    pending = %Pending{
      packet: packet,
      payload: payload,
      from: from,
      tries: 0,
      timer: timer,
      mode: mode
    }

    next_sequence = rem(sequence + 1, 256)

    state
    |> Map.put(:sequence, next_sequence)
    |> Map.update(:pending_list, nil, &Map.put(&1, sequence, pending))
  end

  @spec handle_info({:send, integer}, State.t()) ::
          {:noreply, State.t()} | {:stop, :normal, State.t()}
  def handle_info({:send, sequence}, state) do
    if Map.has_key?(state.pending_list, sequence) do
      pending = state.pending_list[sequence]

      cond do
        pending.mode == :forget ->
          Logger.debug("#{prefix(state)} Sending seq #{sequence} and forgetting.")
          send(state, pending.packet, pending.payload)
          state = Map.update(state, :pending_list, nil, &Map.delete(&1, sequence))
          {:noreply, state}

        pending.tries < get_max_retries() ->
          Logger.debug("#{prefix(state)} Sending seq #{sequence} tries #{pending.tries}.")
          send(state, pending.packet, pending.payload)
          timer = Process.send_after(self(), {:send, sequence}, get_wait_between_retry())
          pending = %Pending{pending | tries: pending.tries + 1, timer: timer}
          state = Map.update(state, :pending_list, nil, &Map.put(&1, sequence, pending))
          {:noreply, state}

        true ->
          Logger.debug("#{prefix(state)} Failed sending seq #{sequence} tries #{pending.tries}.")

          Enum.each(state.pending_list, fn {_, p} ->
            if is_nil(pending.from) do
              Logger.debug("#{prefix(state)} Too many retries, not alerting sender.")
            else
              Logger.debug("#{prefix(state)} Too many retries, alerting sender.")
              GenServer.reply(p.from, {:error, "Too many retries"})
            end
          end)

          state = Map.update(state, :pending_list, nil, &Map.delete(&1, sequence))
          {:noreply, state}
      end
    else
      Logger.debug("#{prefix(state)} Sending seq #{sequence}, no record, presumed already done.")
      {:noreply, state}
    end
  end

  def handle_info(:dead, %State{} = state) do
    # Timer expired, meaning we haven't seen any packets in a while.
    # Try to poll device to make sure it is really dead.
    Logger.info("#{prefix(state)} Device has timed out.")
    Poller.poll_device(state.device)
    {:noreply, state}
  end

  @spec send(State.t(), Packet.t(), bitstring()) :: :ok
  defp send(%State{} = state, %Packet{} = packet, payload) do
    get_udp().send(
      state.udp,
      state.device.host,
      state.device.port,
      %Packet{
        packet
        | :frame_header => %FrameHeader{packet.frame_header | :source => state.source}
      }
      |> Protocol.create_packet(payload)
    )

    :ok
  end
end
