defmodule Lifx.Device do
    use GenServer, restart: :transient
    use Lifx.Protocol.Types
    require Logger
    alias Lifx.Protocol.{FrameHeader, FrameAddress, ProtocolHeader}
    alias Lifx.Protocol.Packet
    alias Lifx.Protocol.{HSBK, Group, Location}
    alias Lifx.Protocol
    alias Lifx.Client

    @max_api_timeout Application.get_env(:lifx, :max_api_timeout)
    @max_retries Application.get_env(:lifx, :max_retries)
    @wait_between_retry Application.get_env(:lifx, :wait_between_retry)

    defmodule Pending do
        @enforce_keys [:packet, :payload, :from, :tries, :timer]
        defstruct packet: nil, payload: nil, from: nil, tries: 0, timer: nil
    end

    defmodule State do
        defstruct id: 0,
            host: {0,0,0,0},
            port: 57600,
            label: nil,
            power: 0,
            signal: 0,
            rx: 0,
            tx: 0,
            hsbk: %HSBK{},
            group: %Group{},
            location: %Location{},
            sequence: 0,
            pending_list: %{}
    end

    defp prefix(state) do
        "Light #{state.id}/#{state.label}:"
    end

    def start_link(%State{} = device) do
        GenServer.start_link(__MODULE__, device, name: device.id)
    end

    def set_color(%State{id: id}, %HSBK{} = hsbk, duration \\ 1000) do
        GenServer.cast(id, {:set_color, hsbk, duration})
    end

    def on(%State{} = device) do
        set_power(device, 65535)
    end

    def off(%State{} = device) do
        set_power(device, 0)
    end

    def set_power(%State{id: id}, power) do
        GenServer.cast(id, {:set_power, power})
    end

    def set_color_wait(%State{id: id}, %HSBK{} = hsbk, duration \\ 1000) do
        with {:ok, payload} <- GenServer.call(id, {:set_color, hsbk, duration}, @max_api_timeout) do
            {:ok, payload.hsbk}
        else
            {:error, err} -> {:error, err}
        end
    catch
        :exit, {:noproc, _} -> {:error, "The light #{id} is dead."}
    end

    def on_wait(%State{} = device) do
        set_power_wait(device, 65535)
    end

    def off_wait(%State{} = device) do
        set_power_wait(device, 0)
    end

    def set_power_wait(%State{id: id}, power) do
        with {:ok, payload} <- GenServer.call(id, {:set_power, power}, @max_api_timeout) do
            {:ok, payload.level}
        else
            {:error, err} -> {:error, err}
        end
    catch
        :exit, {:noproc, _} -> {:error, "The light #{id} is dead."}
    end

    def get_location(%State{id: id}) do
        with {:ok, payload} <- GenServer.call(id, {:get_location}, @max_api_timeout) do
            {:ok, payload.location}
        else
            {:error, err} -> {:error, err}
        end
    catch
        :exit, {:noproc, _} -> {:error, "The light #{id} is dead."}
    end

    def get_label(%State{id: id}) do
        with {:ok, payload} <- GenServer.call(id, {:get_label}, @max_api_timeout) do
            {:ok, payload.label}
        else
            {:error, err} -> {:error, err}
        end
    catch
        :exit, {:noproc, _} -> {:error, "The light #{id} is dead."}
    end

    def get_color(%State{id: id}) do
        with {:ok, payload} <- GenServer.call(id, {:get_color}, @max_api_timeout) do
            {:ok, payload.hsbk}
        else
            {:error, err} -> {:error, err}
        end
    catch
        :exit, {:noproc, _} -> {:error, "The light #{id} is dead."}
    end

    def get_wifi(%State{id: id}) do
        GenServer.call(id, {:get_wifi}, @max_api_timeout)
    catch
        :exit, {:noproc, _} -> {:error, "The light #{id} is dead."}
    end

    def get_power(%State{id: id}) do
        with {:ok, payload} <- GenServer.call(id, {:get_power}, @max_api_timeout) do
            {:ok, payload.level}
        else
            {:error, err} -> {:error, err}
        end
    catch
        :exit, {:noproc, _} -> {:error, "The light #{id} is dead."}
    end

    def get_group(%State{id: id}) do
        with {:ok, payload} <- GenServer.call(id, {:get_location}, @max_api_timeout) do
            {:ok, payload.location}
        else
            {:error, err} -> {:error, err}
        end
    catch
        :exit, {:noproc, _} -> {:error, "The light #{id} is dead."}
    end

    def packet(id, %Packet{} = packet) do
        GenServer.call(id, {:packet, packet})
    end

    def host_update(id, host, port) do
        GenServer.call(id, {:update_host, host, port})
    end

    def init(%State{} = device) do
        Lifx.Poller.schedule_device(Lifx.Poller, device)
        {:ok, device}
    end

    defp handle_packet(%Packet{:protocol_header => %ProtocolHeader{:type => @statelabel}} = packet, state) do
        s = %State{state | :label => packet.payload.label}
        notify(s)
        s
    end

    defp handle_packet(%Packet{:protocol_header => %ProtocolHeader{:type => @statepower}} = packet, state) do
        s = %State{state | :power => packet.payload.level}
        notify(s)
        s
    end

    defp handle_packet(%Packet{:protocol_header => %ProtocolHeader{:type => @stategroup}} = packet, state) do
        s = %State{state | :group => packet.payload.group}
        notify(s)
        s
    end

    defp handle_packet(%Packet{:protocol_header => %ProtocolHeader{:type => @statelocation}} = packet, state) do
        s = %State{state | :location => packet.payload.location}
        notify(s)
        s
    end

    defp handle_packet(%Packet{:protocol_header => %ProtocolHeader{:type => @light_state}} = packet, state) do
        s = %State{state |
            :hsbk => packet.payload.hsbk,
            :power => packet.payload.power,
            :label => packet.payload.label,
        }
        notify(s)
        s
    end

    defp handle_packet(%Packet{:protocol_header => %ProtocolHeader{:type => @statewifiinfo}} = packet, state) do
        s = %State{state |
            :signal => packet.payload.signal,
            :rx => packet.payload.rx,
            :tx => packet.payload.tx,
        }
        notify(s)
        s
    end

    defp handle_packet(_packet, state) do
        state
    end

    def handle_call({:packet, %Packet{} = packet}, _from, state) do
        state = handle_packet(packet, state)
        sequence = packet.frame_address.sequence
        state =
            if Map.has_key?(state.pending_list, sequence) do
                pending = state.pending_list[sequence]
                Process.cancel_timer(pending.timer)
                if not is_nil(pending.from) do
                    Logger.debug("#{prefix state} Got seq #{sequence}, alerting sender.")
                    GenServer.reply(pending.from, {:ok, packet.payload})
                else
                    Logger.debug("#{prefix state} Got seq #{sequence}, not alerting sender.")
                end
                Map.update(state, :pending_list, nil, &(Map.delete(&1, sequence)))
            else
                Logger.debug("#{prefix state} Got seq #{sequence}, no record, presumed already done.")
                state
            end
        {:reply, state, state}
    end

    def handle_call({:update_host, host, port}, _from, state) do
        s = %State{state |
            :host => host,
            :port => port
        }
        notify(s)
        {:reply, s, s}
    end

    def handle_call({:set_color, %HSBK{} = hsbk, duration}, from, state) do
        packet = %Packet{
            :frame_header => %FrameHeader{},
            :frame_address => %FrameAddress{target: state.id, res_required: 1},
            :protocol_header => %ProtocolHeader{type: @light_setcolor}
        }
        payload = Protocol.hsbk(hsbk, duration)
        state = schedule_packet(state, packet, payload, from)
        {:noreply, state}
    end

    def handle_call({:set_power, power}, from, state) do
        packet = %Packet{
            :frame_header => %FrameHeader{},
            :frame_address => %FrameAddress{target: state.id, res_required: 1},
            :protocol_header => %ProtocolHeader{type: @setpower}
        }
        payload = Protocol.level(power)
        state = schedule_packet(state, packet, payload, from)
        {:noreply, state}
    end

    def handle_call({:get_location}, from, state) do
        location_packet = %Packet{
            :frame_header => %FrameHeader{},
            :frame_address => %FrameAddress{target: state.id},
            :protocol_header => %ProtocolHeader{type: @getlocation}
        }
        state = schedule_packet(state, location_packet, <<>>, from)
        {:noreply, state}
    end

    def handle_call({:get_label}, from, state) do
        label_packet = %Packet{
            :frame_header => %FrameHeader{},
            :frame_address => %FrameAddress{target: state.id},
            :protocol_header => %ProtocolHeader{type: @getlabel}
        }
        state = schedule_packet(state, label_packet, <<>>, from)
        {:noreply, state}
    end

    def handle_call({:get_color}, from, state) do
        color_packet = %Packet{
            :frame_header => %FrameHeader{},
            :frame_address => %FrameAddress{target: state.id},
            :protocol_header => %ProtocolHeader{type: @light_get}
        }
        state = schedule_packet(state, color_packet, <<>>, from)
        {:noreply, state}
    end

    def handle_call({:get_wifi}, from, state) do
        wifi_packet = %Packet{
            :frame_header => %FrameHeader{},
            :frame_address => %FrameAddress{target: state.id},
            :protocol_header => %ProtocolHeader{type: @getwifiinfo}
        }
        state = schedule_packet(state, wifi_packet, <<>>, from)
        {:noreply, state}
    end

    def handle_call({:get_power}, from, state) do
        power_packet = %Packet{
            :frame_header => %FrameHeader{},
            :frame_address => %FrameAddress{target: state.id},
            :protocol_header => %ProtocolHeader{type: @getpower}
        }
        state = schedule_packet(state, power_packet, <<>>, from)
        {:noreply, state}
    end

    def handle_call({:get_group}, from, state) do
        group_packet = %Packet{
            :frame_header => %FrameHeader{},
            :frame_address => %FrameAddress{target: state.id},
            :protocol_header => %ProtocolHeader{type: @getgroup}
        }
        state = schedule_packet(state, group_packet, <<>>, from)
        {:noreply, state}
    end

    def handle_cast({:set_color, %HSBK{} = hsbk, duration}, state) do
        packet = %Packet{
            :frame_header => %FrameHeader{},
            :frame_address => %FrameAddress{target: state.id, res_required: 1},
            :protocol_header => %ProtocolHeader{type: @light_setcolor}
        }
        payload = Protocol.hsbk(hsbk, duration)
        state = schedule_packet(state, packet, payload, nil)
        {:noreply, state}
    end

    def handle_cast({:set_power, power}, state) do
        packet = %Packet{
            :frame_header => %FrameHeader{},
            :frame_address => %FrameAddress{target: state.id, res_required: 1},
            :protocol_header => %ProtocolHeader{type: @setpower}
        }
        payload = Protocol.level(power)
        state = schedule_packet(state, packet, payload, nil)
        {:noreply, state}
    end

    defp schedule_packet(state, packet, payload, from) do
        sequence = state.sequence
        Logger.debug("#{prefix state} Scheduling seq #{sequence}.")

        packet = put_in(packet.frame_address.sequence, sequence)

        timer = Process.send_after(self(), {:send, sequence}, 0)

        pending = %Pending{
            packet: packet,
            payload: payload,
            from: from,
            tries: 0,
            timer: timer
        }


        next_sequence = rem(sequence + 1, 256)

        state
        |> Map.put(:sequence, next_sequence)
        |> Map.update(:pending_list, nil, &(Map.put(&1, sequence, pending)))
    end

    def handle_info({:send, sequence}, state) do
        if Map.has_key?(state.pending_list, sequence) do
            pending = state.pending_list[sequence]
            cond do
                pending.tries < @max_retries ->
                    Logger.debug("#{prefix state} Sending seq #{sequence} tries #{pending.tries}.")
                    Client.send(state, pending.packet, pending.payload)
                    timer = Process.send_after(self(), {:send, sequence}, @wait_between_retry)
                    pending = %Pending{pending | tries: pending.tries + 1, timer: timer}
                    state = Map.update(state, :pending_list, nil, &(Map.put(&1, sequence, pending)))
                    {:noreply, state}
                true ->
                    Logger.debug("#{prefix state} Failed sending seq #{sequence} tries #{pending.tries}, killing light.")
                    Client.remove_light(state)
                    Enum.each(state.pending_list, fn {_, p} ->
                        GenServer.reply(p.from, {:error, "Too many retries"})
                    end)
                    state = Map.update(state, :pending_list, nil, &(Map.delete(&1, sequence)))
                    {:stop, :normal, state}
            end
        else
            Logger.debug("#{prefix state} Sending seq #{sequence}, no record, presumed already done.")
            {:noreply, state}
        end
    end

    defp notify(msg) do
        for {_, pid, _, _} <- Supervisor.which_children(Lifx.Client.Events) do
            GenServer.cast(pid, msg)
        end
        :ok
    end
end
