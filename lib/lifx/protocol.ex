defmodule Lifx.Protocol do
  @moduledoc "Types used by the LIFX protocols"

  use Lifx.Protocol.Types

  defmodule FrameHeader do
    @moduledoc "A LIFX FrameHeader portion of the packet"
    @type t :: %__MODULE__{
            origin: integer(),
            tagged: integer(),
            addressable: integer(),
            protocol: integer(),
            source: integer
          }
    defstruct size: 0,
              origin: 0,
              tagged: 0,
              addressable: 1,
              protocol: 1024,
              source: 0
  end

  defmodule FrameAddress do
    @moduledoc "A LIFX FrameAddress portion of the packet"
    @type t :: %__MODULE__{
            target: integer() | :all,
            ack_required: integer(),
            res_required: integer(),
            sequence: byte()
          }
    defstruct target: :all,
              ack_required: 0,
              res_required: 0,
              sequence: 0
  end

  defmodule ProtocolHeader do
    @moduledoc "A LIFX ProtocolHeader portion of the packet"
    @type t :: %__MODULE__{
            type: integer()
          }
    defstruct type: 2
  end

  defmodule Packet do
    @moduledoc "A LIFX Packet"
    @type t :: %__MODULE__{
            frame_header: FrameHeader.t(),
            frame_address: FrameAddress.t(),
            protocol_header: ProtocolHeader.t(),
            payload: map()
          }
    @enforce_keys [:frame_header, :frame_address, :protocol_header]
    defstruct frame_header: nil,
              frame_address: nil,
              protocol_header: nil,
              payload: %{}
  end

  defmodule Group do
    @moduledoc "A LIFX group"
    @type t :: %__MODULE__{
            label: String.t(),
            updated_at: integer
          }
    defstruct id: [],
              label: nil,
              updated_at: 0
  end

  defmodule Location do
    @moduledoc "A LIFX location"
    @type t :: %__MODULE__{
            label: String.t(),
            updated_at: integer
          }
    defstruct id: [],
              label: nil,
              updated_at: 0
  end

  defmodule HSBK do
    @moduledoc "A LIFX colors"
    @type t :: %__MODULE__{
            hue: integer() | float(),
            saturation: integer() | float(),
            brightness: integer() | float(),
            kelvin: integer() | float()
          }
    defstruct hue: 120,
              saturation: 100,
              brightness: 100,
              kelvin: 4000
  end

  @spec hue(HSBK.t()) :: integer
  defp hue(%HSBK{} = hsbk) do
    round(65_535 / 360 * hsbk.hue)
  end

  @spec saturation(HSBK.t()) :: integer
  defp saturation(%HSBK{} = hsbk) do
    round(65_535 / 100 * hsbk.saturation)
  end

  @spec brightness(HSBK.t()) :: integer
  defp brightness(%HSBK{} = hsbk) do
    round(65_535 / 100 * hsbk.brightness)
  end

  @spec kelvin(HSBK.t()) :: integer
  defp kelvin(%HSBK{} = hsbk) do
    round(hsbk.kelvin)
  end

  defmodule HSBKS do
    @moduledoc "A list of LIFX colors"
    @type t :: %__MODULE__{
            total_available: integer(),
            index: integer(),
            list: list(HSBK.t())
          }
    defstruct total_available: 0,
              index: 0,
              list: []
  end

  @spec parse_payload(Packet.t(), bitstring()) :: Packet.t()

  def parse_payload(
        %Packet{:protocol_header => %ProtocolHeader{:type => @stateservice}} = packet,
        payload
      ) do
    <<
      service::little-integer-size(8),
      port::little-integer-size(32)
    >> = payload

    %Packet{packet | :payload => %{:service => service, :port => port}}
  end

  def parse_payload(
        %Packet{:protocol_header => %ProtocolHeader{:type => @statehostinfo}} = packet,
        payload
      ) do
    <<
      signal::little-float-size(32),
      tx::little-integer-size(32),
      rx::little-integer-size(32),
      _::signed-little-integer-size(16)
    >> = payload

    %Packet{packet | :payload => %{:signal => signal, :tx => tx, :rx => rx}}
  end

  def parse_payload(
        %Packet{:protocol_header => %ProtocolHeader{:type => @light_state}} = packet,
        payload
      ) do
    <<
      hsbk::bits-size(64),
      _::signed-little-size(16),
      power::little-size(16),
      label::bytes-size(32),
      _::little-size(64)
    >> = payload

    %Packet{
      packet
      | :payload => %{
          :hsbk => parse_hsbk(hsbk),
          :power => power,
          :label => parse_label(label)
        }
    }
  end

  def parse_payload(
        %Packet{:protocol_header => %ProtocolHeader{:type => @statelabel}} = packet,
        payload
      ) do
    %Packet{packet | :payload => %{:label => parse_label(payload)}}
  end

  def parse_payload(
        %Packet{:protocol_header => %ProtocolHeader{:type => @statepower}} = packet,
        payload
      ) do
    level = parse_level(payload)
    %Packet{packet | :payload => %{:level => level}}
  end

  def parse_payload(
        %Packet{:protocol_header => %ProtocolHeader{:type => @stategroup}} = packet,
        payload
      ) do
    <<
      id::bytes-size(16),
      label::bytes-size(32),
      updated_at::size(64)
    >> = payload

    %Packet{
      packet
      | :payload => %{
          :group => %Group{
            :id => id,
            :label => parse_label(label),
            :updated_at => updated_at
          }
        }
    }
  end

  def parse_payload(
        %Packet{:protocol_header => %ProtocolHeader{:type => @statelocation}} = packet,
        payload
      ) do
    <<
      id::bytes-size(16),
      label::bytes-size(32),
      updated_at::size(64)
    >> = payload

    %Packet{
      packet
      | :payload => %{
          :location => %Location{
            :id => id,
            :label => parse_label(label),
            :updated_at => updated_at
          }
        }
    }
  end

  def parse_payload(
        %Packet{:protocol_header => %ProtocolHeader{:type => @statewifiinfo}} = packet,
        payload
      ) do
    <<
      signal::little-float-size(32),
      rx::little-size(32),
      tx::little-size(32),
      _::signed-little-size(16)
    >> = payload

    %Packet{
      packet
      | :payload => %{
          :signal => signal,
          :rx => rx,
          :tx => tx
        }
    }
  end

  def parse_payload(
        %Packet{:protocol_header => %ProtocolHeader{:type => @state_extended_color_zones}} =
          packet,
        payload
      ) do
    <<
      count::little-size(16),
      index::little-size(16),
      colors_count::little-size(8),
      colors::binary
    >> = payload

    hsbk_list = parse_hsbk_list(colors, colors_count)

    %Packet{
      packet
      | :payload => %HSBKS{
          total_available: count,
          index: index,
          list: hsbk_list
        }
    }
  end

  def parse_payload(%Packet{} = packet, _payload) do
    packet
  end

  @spec label(String.t()) :: bitstring()
  def label(label) do
    <<label::bytes-size(32)>>
  end

  @spec parse_label(bitstring()) :: String.t()
  def parse_label(payload) do
    <<label::bytes-size(32)>> = payload
    String.trim_trailing(label, <<0>>)
  end

  @spec hsbk(HSBK.t()) :: bitstring()
  def hsbk(%HSBK{} = hsbk) do
    <<
      hue(hsbk)::little-integer-size(16),
      saturation(hsbk)::little-integer-size(16),
      brightness(hsbk)::little-integer-size(16),
      kelvin(hsbk)::little-integer-size(16)
    >>
  end

  @spec set_color(HSBK.t(), integer()) :: bitstring()
  def set_color(%HSBK{} = hsbk, duration) do
    <<
      0::little-integer-size(8),
      hsbk(hsbk)::binary-size(8),
      duration::little-integer-size(32)
    >>
  end

  @spec parse_hsbk(bitstring()) :: HSBK.t()
  def parse_hsbk(payload) do
    <<
      hue::little-integer-size(16),
      saturation::little-integer-size(16),
      brightness::little-integer-size(16),
      kelvin::little-integer-size(16)
    >> = payload

    hue = round(360 / 65_535 * hue)
    saturation = round(100 / 65_535 * saturation)
    brightness = round(100 / 65_535 * brightness)
    %HSBK{:hue => hue, :saturation => saturation, :brightness => brightness, :kelvin => kelvin}
  end

  @spec parse_hsbk_list(bitstring(), integer) :: list(HSBK.t())
  def parse_hsbk_list(payload, count) when count > 0 do
    <<hsbk::binary-size(8), rest::binary>> = payload
    [parse_hsbk(hsbk) | parse_hsbk_list(rest, count - 1)]
  end

  def parse_hsbk_list(_, 0), do: []

  @spec level(integer()) :: bitstring()
  def level(level) do
    <<level::size(16)>>
  end

  @spec level(bitstring()) :: integer()
  def parse_level(payload) do
    <<level::size(16)>> = payload
    level
  end

  @spec parse_packet(bitstring()) :: Packet.t()
  def parse_packet(payload) do
    <<
      size::little-integer-size(16),
      otap::bits-size(16),
      source::little-integer-size(32),
      target::little-integer-size(64),
      _::little-integer-size(48),
      rar::bits-size(8),
      sequence::little-integer-size(8),
      _::little-integer-size(64),
      type::little-integer-size(16),
      _::little-integer-size(16),
      rest::binary
    >> = payload

    <<
      origin::size(2),
      tagged::size(1),
      addressable::size(1),
      protocol::size(12)
    >> = reverse_bits(otap)

    <<
      _::size(6),
      ack_required::size(1),
      res_required::size(1)
    >> = reverse_bits(rar)

    target =
      case target do
        0 -> :all
        target -> target
      end

    fh = %FrameHeader{
      :size => size,
      :origin => origin,
      :tagged => tagged,
      :addressable => addressable,
      :protocol => protocol,
      :source => source
    }

    fa = %FrameAddress{
      :target => target,
      :ack_required => ack_required,
      :res_required => res_required,
      :sequence => sequence
    }

    ph = %ProtocolHeader{
      :type => type
    }

    packet = %Packet{
      :frame_header => fh,
      :frame_address => fa,
      :protocol_header => ph
    }

    parse_payload(packet, rest)
  end

  @spec create_packet(Packet.t(), bitstring()) :: bitstring()
  def create_packet(%Packet{} = packet, payload \\ <<>>) when is_binary(payload) do
    target =
      case packet.frame_address.target do
        :all -> 0
        target -> target
      end

    otap =
      reverse_bits(<<
        packet.frame_header.origin::size(2),
        packet.frame_header.tagged::size(1),
        packet.frame_header.addressable::size(1),
        packet.frame_header.protocol::size(12)
      >>)

    rar =
      reverse_bits(<<
        0::size(6),
        packet.frame_address.ack_required::size(1),
        packet.frame_address.res_required::size(1)
      >>)

    p =
      <<
        otap::bits-size(16),
        packet.frame_header.source::little-integer-size(32),
        target::little-integer-size(64),
        0::little-integer-size(48),
        rar::bits-size(8),
        packet.frame_address.sequence::little-integer-size(8),
        0::little-integer-size(64),
        packet.protocol_header.type::little-integer-size(16),
        0::little-integer-size(16)
      >> <> payload

    <<byte_size(p) + 2::little-integer-size(16)>> <> p
  end

  @spec reverse_bits(bitstring()) :: bitstring()
  defp reverse_bits(bits) do
    bits
    |> :erlang.binary_to_list()
    |> :lists.reverse()
    |> :erlang.list_to_binary()
  end

  @spec set_extended_color_zones(
          HSBKS.t(),
          integer,
          :no_apply | :apply | :apply_only
        ) :: bitstring()
  def set_extended_color_zones(colors, duration, apply) do
    apply_int =
      case apply do
        :no_apply -> 0
        :apply -> 1
        :apply_only -> 2
      end

    result = Enum.map(colors.list, fn color -> hsbk(color) end)

    head = <<
      duration::little-integer-size(32),
      apply_int::little-integer-size(8),
      colors.index::little-integer-size(16),
      length(colors.list)::little-integer-size(8)
    >>

    Enum.join([head | result], <<>>)
  end
end
