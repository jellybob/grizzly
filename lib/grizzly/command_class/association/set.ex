defmodule Grizzly.CommandClass.Association.Set do
  @moduledoc """
  Command for working with Association command class SET command

  Command Options:

    * `:group` - The association group
    * `:nodes` - List of node ids to receive messages about node events
    * `:seq_number` - The sequence number used in the Z/IP packet
    * `:retries` - The number of attempts to send the command (default 2)
  """
  @behaviour Grizzly.Command

  alias Grizzly.{Node, Packet}
  alias Grizzly.Network.State, as: NetworkState

  @type t :: %__MODULE__{
          group: byte,
          nodes: associated_nodes,
          seq_number: Grizzly.seq_number(),
          retries: non_neg_integer(),
          exec_state: NetworkState.state() | nil,
          pre_states: [NetworkState.state()]
        }

  @type associated_nodes :: [Node.node_id()]

  @type opts ::
          {:group, byte}
          | {:nodes, associated_nodes}
          | {:seq_number, Grizzly.seq_number()}
          | {:retries, non_neg_integer()}
          | {:pre_states, [NetworkState.state()]}
          | {:exec_state, NetworkState.state()}

  defstruct group: nil,
            nodes: nil,
            seq_number: nil,
            retries: 2,
            exec_state: nil,
            pre_states: [:not_ready, :idle]

  @spec init([opts]) :: {:ok, t}
  def init(opts) do
    {:ok, struct(__MODULE__, opts)}
  end

  @spec encode(t) :: {:ok, binary}
  def encode(%__MODULE__{group: group, nodes: nodes, seq_number: seq_number}) do
    binary = Packet.header(seq_number) <> <<0x85, 0x01, group>> <> :erlang.list_to_binary(nodes)

    {:ok, binary}
  end

  @spec handle_response(t, Packet.t()) ::
          {:continue, t()}
          | {:done, {:error, :nack_response}}
          | {:done, :ok}
          | {:retry, t()}
          | {:queued, t()}
  def handle_response(
        %__MODULE__{seq_number: seq_number},
        %Packet{
          seq_number: seq_number,
          types: [:ack_response]
        }
      ) do
    {:done, :ok}
  end

  def handle_response(
        %__MODULE__{seq_number: seq_number, retries: 0},
        %Packet{
          seq_number: seq_number,
          types: [:nack_response]
        }
      ) do
    {:done, {:error, :nack_response}}
  end

  def handle_response(
        %__MODULE__{seq_number: seq_number, retries: n} = command,
        %Packet{
          seq_number: seq_number,
          types: [:nack_response]
        }
      ) do
    {:retry, %{command | retries: n - 1}}
  end

  def handle_response(
        %__MODULE__{seq_number: seq_number} = command,
        %Packet{
          seq_number: seq_number,
          types: [:nack_response, :nack_waiting]
        } = packet
      ) do
    netstate = Grizzly.Network.get_state()

    if Packet.sleeping_delay?(packet) && netstate != :configurating_new_node do
      {:queued, command}
    else
      {:continue, command}
    end
  end

  def handle_response(command, _), do: {:continue, command}
end