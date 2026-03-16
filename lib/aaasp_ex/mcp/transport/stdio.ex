defmodule AaaspEx.Mcp.Transport.Stdio do
  @moduledoc """
  MCP transport over stdio — spawns a local process and communicates
  via newline-delimited JSON on stdin/stdout.

  Incoming messages are forwarded to the `owner` process as
  `{:mcp_message, map()}`.
  """

  @behaviour AaaspEx.Mcp.Transport

  use GenServer
  require Logger

  defstruct [:port, :owner, :buffer]

  @impl AaaspEx.Mcp.Transport
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl AaaspEx.Mcp.Transport
  def send_message(transport, message) do
    GenServer.call(transport, {:send, message})
  end

  @impl AaaspEx.Mcp.Transport
  def stop(transport) do
    GenServer.stop(transport, :normal)
  end

  # -- GenServer --

  @impl true
  def init(opts) do
    command = Keyword.fetch!(opts, :command)
    args = Keyword.get(opts, :args, [])
    env = Keyword.get(opts, :env, [])
    owner = Keyword.fetch!(opts, :owner)

    executable =
      case System.find_executable(command) do
        nil -> raise "MCP: executable not found: #{command}"
        path -> to_charlist(path)
      end

    port_opts = [
      :binary,
      :exit_status,
      :use_stdio,
      {:args, args},
      {:env, Enum.map(env, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)},
      {:line, 1_048_576}
    ]

    port = Port.open({:spawn_executable, executable}, port_opts)

    {:ok, %__MODULE__{port: port, owner: owner, buffer: ""}}
  end

  @impl true
  def handle_call({:send, message}, _from, state) do
    json = Jason.encode!(message)
    Port.command(state.port, json <> "\n")
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) do
    line = state.buffer <> line

    case Jason.decode(line) do
      {:ok, msg} ->
        send(state.owner, {:mcp_message, msg})

      {:error, _} ->
        Logger.debug("[MCP.Stdio] non-JSON line: #{inspect(line)}")
    end

    {:noreply, %{state | buffer: ""}}
  end

  def handle_info({port, {:data, {:noeol, chunk}}}, %{port: port} = state) do
    {:noreply, %{state | buffer: state.buffer <> chunk}}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    send(state.owner, {:mcp_transport_closed, status})
    {:stop, {:server_exited, status}, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %{port: port}) do
    if Port.info(port), do: Port.close(port)
    :ok
  end
end
