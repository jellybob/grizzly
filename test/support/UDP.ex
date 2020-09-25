defmodule GrizzlyTest.Transport.UDP do
  @moduledoc false

  @behaviour Grizzly.Transport

  alias Grizzly.{Transport, ZWave}

  @test_host {0, 0, 0, 0}
  @test_port 5_000

  @impl Grizzly.Transport
  def open(args) do
    case Keyword.get(args, :ip_address) do
      {0, 0, 0, 600} ->
        {:error, :timeout}

      {0, 0, 0, node_id} ->
        {:ok, socket} = :gen_udp.open(@test_port + node_id, [:binary, {:active, true}])
        {:ok, Transport.new(__MODULE__, %{socket: socket})}
    end
  end

  @impl Grizzly.Transport
  def send(transport, binary) do
    transport
    |> Transport.get_priv(:socket)
    |> :gen_udp.send(@test_host, @test_port, binary)
  end

  @impl Grizzly.Transport
  def parse_response({:udp, _, _, _, binary}) do
    case ZWave.from_binary(binary) do
      {:ok, _zip_packet} = result -> result
    end
  end

  @impl Grizzly.Transport
  def close(transport) do
    transport
    |> Transport.get_priv(:socket)
    |> :gen_udp.close()
  end
end
