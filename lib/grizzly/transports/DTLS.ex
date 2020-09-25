defmodule Grizzly.Transports.DTLS do
  @moduledoc """
  DTLS implementation of the `Grizzly.Transport` behaviour
  """

  @behaviour Grizzly.Transport

  alias Grizzly.{Transport, ZWave}

  require Logger

  @impl Grizzly.Transport
  def open(args) do
    ip_address = Keyword.fetch!(args, :ip_address)
    port = Keyword.fetch!(args, :port)

    case :ssl.connect(ip_address, port, dtls_opts(), 10_000) do
      {:ok, socket} -> {:ok, Transport.new(__MODULE__, %{socket: socket})}
      {:error, _} = error -> error
    end
  end

  @impl Grizzly.Transport
  def send(transport, binary) do
    socket = Transport.get_priv(transport, :socket)
    :ssl.send(socket, binary)
  end

  @impl Grizzly.Transport
  def parse_response({:ssl, {:sslsocket, {:gen_udp, _, :dtls_connection}, _}, bin_list}) do
    binary = :erlang.list_to_binary(bin_list)

    # TODO: handle errors
    {:ok, _result} = result = ZWave.from_binary(binary)
    result
  end

  @impl Grizzly.Transport
  def close(transport) do
    transport
    |> Transport.get_priv(:socket)
    |> :ssl.close()
  end

  @doc false
  def user_lookup(:psk, _username, userstate) do
    {:ok, userstate}
  end

  defp dtls_opts() do
    [
      {:ssl_imp, :new},
      {:active, true},
      {:verify, :verify_none},
      {:versions, [:dtlsv1]},
      {:protocol, :dtls},
      {:ciphers, [{:psk, :aes_128_cbc, :sha}]},
      {:psk_identity, 'Client_identity'},
      {:user_lookup_fun,
       {&user_lookup/3,
        <<0x12, 0x34, 0x56, 0x78, 0x90, 0x12, 0x34, 0x56, 0x78, 0x90, 0x12, 0x34, 0x56, 0x78,
          0x90, 0xAA>>}},
      {:cb_info, {:gen_udp, :udp, :udp_close, :udp_error}},
      :inet6
    ]
  end
end
