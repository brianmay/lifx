defmodule Lifx.Device do
  @moduledoc false

  use Lifx.Protocol.Types
  require Logger
  alias Lifx.Device
  alias Lifx.Protocol
  alias Lifx.Protocol.{Group, HSBK, HSBKS, Location}
  alias Lifx.Protocol.Packet

  defp get_max_api_timeout, do: Application.get_env(:lifx, :max_api_timeout)

  @type t :: %__MODULE__{
          id: atom(),
          pid: GenServer.server() | nil,
          host: tuple(),
          port: integer(),
          label: String.t(),
          group: Group.t(),
          location: Location.t()
        }

  @enforce_keys [:id, :pid, :host, :port]
  defstruct id: 0,
            pid: nil,
            host: {0, 0, 0, 0},
            port: 56_700,
            label: nil,
            group: %Group{},
            location: %Location{}

  @spec send_and_forget(Device.t(), integer(), bitstring(), :forget | :retry) :: :ok
  defp send_and_forget(%Device{pid: pid}, protocol_type, payload, mode) do
    GenServer.cast(pid, {:send, protocol_type, payload, mode})
    :ok
  end

  @spec send_and_wait(Device.t(), integer(), bitstring(), :retry | :response) ::
          {:ok, map()} | {:error, String.t()}
  defp send_and_wait(%Device{pid: pid, id: id}, protocol_type, payload, mode) do
    request = {:send, protocol_type, payload, mode}

    case GenServer.call(pid, request, get_max_api_timeout()) do
      {:ok, payload} -> {:ok, payload}
      {:error, err} -> {:error, err}
    end
  catch
    :exit, value -> {:error, "The device #{id} is dead: #{inspect(value)}"}
  end

  @spec set_color(Device.t(), HSBK.t(), integer) :: :ok
  def set_color(%Device{} = device, %HSBK{} = hsbk, duration \\ 1000) do
    payload = Protocol.set_color(hsbk, duration)
    send_and_forget(device, @light_setcolor, payload, :retry)
  end

  @spec on(Device.t()) :: :ok
  def on(%Device{} = device) do
    set_power(device, 65_535)
  end

  @spec off(Device.t()) :: :ok
  def off(%Device{} = device) do
    set_power(device, 0)
  end

  @spec set_power(Device.t(), integer) :: :ok
  def set_power(%Device{} = device, power) do
    payload = Protocol.level(power)
    send_and_forget(device, @setpower, payload, :retry)
  end

  @spec set_color_wait(Device.t(), HSBK.t(), integer) :: {:ok, HSBK.t()} | {:error, String.t()}
  def set_color_wait(%Device{} = device, %HSBK{} = hsbk, duration \\ 1000) do
    payload = Protocol.set_color(hsbk, duration)

    case send_and_wait(device, @light_setcolor, payload, :response) do
      {:ok, value} -> {:ok, value.hsbk}
      {:error, value} -> {:error, value}
    end
  end

  @spec on_wait(Device.t()) :: {:ok, HSBK.t()} | {:error, String.t()}
  def on_wait(%Device{} = device) do
    set_power_wait(device, 65_535)
  end

  @spec off_wait(Device.t()) :: {:ok, HSBK.t()} | {:error, String.t()}
  def off_wait(%Device{} = device) do
    set_power_wait(device, 0)
  end

  @spec set_power_wait(Device.t(), integer) :: {:ok, HSBK.t()} | {:error, String.t()}
  def set_power_wait(%Device{} = device, power) do
    payload = Protocol.level(power)

    case send_and_wait(device, @setpower, payload, :response) do
      {:ok, value} -> {:ok, value.level}
      {:error, value} -> {:error, value}
    end
  end

  @spec get_location(Device.t()) :: {:ok, Location.t()} | {:error, String.t()}
  def get_location(%Device{} = device) do
    payload = <<>>

    case send_and_wait(device, @getlocation, payload, :response) do
      {:ok, value} -> {:ok, value.location}
      {:error, value} -> {:error, value}
    end
  end

  @spec get_label(Device.t()) :: {:ok, String.t()} | {:error, String.t()}
  def get_label(%Device{} = device) do
    payload = <<>>

    case send_and_wait(device, @getlabel, payload, :response) do
      {:ok, value} -> {:ok, value.label}
      {:error, value} -> {:error, value}
    end
  end

  @spec get_color(Device.t()) :: {:ok, HSBK.t()} | {:error, String.t()}
  def get_color(%Device{} = device) do
    payload = <<>>

    case send_and_wait(device, @light_get, payload, :response) do
      {:ok, value} -> {:ok, value.hsbk}
      {:error, value} -> {:error, value}
    end
  end

  @spec get_wifi(Device.t()) :: {:ok, map()} | {:error, String.t()}
  def get_wifi(%Device{} = device) do
    payload = <<>>

    case send_and_wait(device, @getwifiinfo, payload, :response) do
      {:ok, value} -> {:ok, value}
      {:error, value} -> {:error, value}
    end
  end

  @spec get_power(Device.t()) :: {:ok, integer} | {:error, String.t()}
  def get_power(%Device{} = device) do
    payload = <<>>

    case send_and_wait(device, @getpower, payload, :response) do
      {:ok, value} -> {:ok, value.level}
      {:error, value} -> {:error, value}
    end
  end

  @spec get_group(Device.t()) :: {:ok, Group.t()} | {:error, String.t()}
  def get_group(%Device{} = device) do
    payload = <<>>

    case send_and_wait(device, @getgroup, payload, :response) do
      {:ok, value} -> {:ok, value.group}
      {:error, value} -> {:error, value}
    end
  end

  @spec packet(Device.t(), Packet.t()) :: :ok | {:error, String.t()}
  def packet(%Device{} = device, %Packet{} = packet) do
    :ok = GenServer.call(device.pid, {:packet, packet})
  catch
    :exit, value -> {:error, "The device #{device.id} is dead: #{inspect(value)}"}
  end

  @spec set_extended_color_zones(
          Device.t(),
          HSBKS.t(),
          integer,
          :no_apply | :apply | :apply_only
        ) :: :ok
  def set_extended_color_zones(
        %Device{} = device,
        %HSBKS{} = colors,
        duration \\ 1000,
        apply \\ :apply
      ) do
    payload = Protocol.set_extended_color_zones(colors, duration, apply)
    send_and_forget(device, @set_extended_color_zones, payload, :retry)
  end

  @spec set_extended_color_zones_wait(
          Device.t(),
          HSBKS.t(),
          integer,
          :no_apply | :apply | :apply_only
        ) :: {:ok, map()} | {:error, String.t()}
  def set_extended_color_zones_wait(
        %Device{} = device,
        %HSBKS{} = colors,
        duration \\ 1000,
        apply \\ :apply
      ) do
    payload = Protocol.set_extended_color_zones(colors, duration, apply)

    case send_and_wait(device, @set_extended_color_zones, payload, :retry) do
      {:ok, value} -> {:ok, value}
      {:error, value} -> {:error, value}
    end
  end

  @spec get_extended_color_zones(Device.t()) :: {:ok, HSBKS.t()} | {:error, String.t()}
  def get_extended_color_zones(%Device{} = device) do
    payload = <<>>

    case send_and_wait(device, @get_extended_color_zones, payload, :response) do
      {:ok, value} -> {:ok, value}
      {:error, value} -> {:error, value}
    end
  end
end
