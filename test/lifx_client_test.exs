defmodule LifxTest do
  use ExUnit.Case, async: false
  use Lifx.Protocol.Types
  require Logger
  doctest Lifx

  import Mox

  setup :set_mox_global
  setup :verify_on_exit!

  alias Lifx.Device
  alias Lifx.Protocol
  alias Lifx.Protocol.{FrameAddress, FrameHeader, ProtocolHeader}
  alias Lifx.Protocol.Packet

  @discovery_packet %Packet{
    frame_header: %FrameHeader{
      addressable: 1,
      origin: 0,
      protocol: 1024,
      size: 36,
      source: 4_102_800_990,
      tagged: 1
    },
    frame_address: %FrameAddress{
      ack_required: 0,
      res_required: 1,
      sequence: 0,
      target: :all
    },
    protocol_header: %ProtocolHeader{
      type: 2
    },
    payload: %{}
  }

  @discovery_response_packet %Packet{
    frame_header: %FrameHeader{
      addressable: 1,
      origin: 0,
      protocol: 1024,
      size: 36,
      source: 4_102_800_990,
      tagged: 1
    },
    frame_address: %FrameAddress{
      ack_required: 0,
      res_required: 1,
      sequence: 0,
      target: 99
    },
    protocol_header: %ProtocolHeader{
      type: 3
    },
    payload: %{}
  }

  test "discovery packet creation" do
    data = "240000345EC68BF400000000000000000000000000000100000000000000000002000000"
    {:ok, bin} = Base.decode16(data, case: :upper)
    assert Protocol.create_packet(@discovery_packet) == bin
  end

  test "discovery packet parsing" do
    data = "240000345EC68BF400000000000000000000000000000100000000000000000002000000"
    {:ok, bin} = Base.decode16(data, case: :upper)
    assert Protocol.parse_packet(bin) == @discovery_packet
  end

  test "Send Discovery" do
    pid = self()

    Mox.expect(Lifx.UdpMock, :open, 1, fn _port, _options -> {:ok, nil} end)

    Mox.expect(Lifx.UdpMock, :send, 1, fn _socket, _host, _port, payload ->
      packet = Protocol.parse_packet(payload)

      if packet.protocol_header.type != 2 do
        nil
      else
        send(pid, :sent_packet)
      end
    end)

    start_supervised!(Lifx.Supervisor, start: {Lifx.Supervisor, :start_link, []})

    assert_receive(:sent_packet)
  end

  test "Receive Discovery" do
    pid = self()

    Mox.expect(Lifx.UdpMock, :open, 1, fn _port, _options ->
      send(pid, {:pid, self()})
      {:ok, nil}
    end)

    Mox.expect(Lifx.UdpMock, :send, 1, fn _socket, _host, _port, _payload -> nil end)
    start_supervised!(Lifx.Supervisor, start: {Lifx.Supervisor, :start_link, []})

    client_pid =
      receive do
        {:pid, client_pid} -> client_pid
      end

    payload = <<
      1::little-integer-size(8),
      1234::little-integer-size(32)
    >>

    Lifx.Client.add_handler(self())
    fake_response = Protocol.create_packet(@discovery_response_packet, payload)
    send(client_pid, {:udp, nil, "1.2.3.4", nil, fake_response})
    assert_receive({_, {:added, %Device{}}})
    devices = Lifx.Client.devices()
    assert Enum.count(devices) > 0
  end
end
