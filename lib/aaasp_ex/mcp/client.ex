defmodule AaaspEx.Mcp.Client do
  @moduledoc """
  MCP (Model Context Protocol) client for connecting to external tool servers.

  Manages the lifecycle of an MCP server connection over stdio or SSE transport.
  Handles the JSON-RPC 2.0 protocol, initialization handshake, tool discovery,
  and tool invocation.

  ## Stdio (local process)

      {:ok, client} = AaaspEx.Mcp.Client.start_link(
        transport: :stdio,
        command: "npx",
        args: ["-y", "some-mcp-server"]
      )

  ## SSE (remote HTTP server)

      {:ok, client} = AaaspEx.Mcp.Client.start_link(
        transport: :sse,
        url: "https://mcp.example.com/mcp"
      )

  ## Common API

      {:ok, tools} = AaaspEx.Mcp.Client.list_tools(client)
      {:ok, result} = AaaspEx.Mcp.Client.call_tool(client, "tool_name", %{"arg" => "value"})
      AaaspEx.Mcp.Client.disconnect(client)
  """

  use GenServer
  require Logger

  @call_timeout 60_000

  defstruct [
    :transport_mod,
    :transport_pid,
    :next_id,
    :pending,
    :server_info,
    :initialized
  ]

  # -- Public API --

  @doc """
  Start an MCP client and connect to the server.

  ## Options

    * `:transport` — `:stdio` (default) or `:sse`

  ### Stdio options
    * `:command` — executable to spawn (required)
    * `:args` — list of command arguments (default: `[]`)
    * `:env` — list of `{key, value}` env vars (default: `[]`)

  ### SSE options
    * `:url` — HTTP endpoint URL (required)
    * `:headers` — extra HTTP headers (default: `[]`)
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc "List tools exposed by the connected MCP server."
  def list_tools(client, timeout \\ @call_timeout) do
    GenServer.call(client, :list_tools, timeout)
  end

  @doc "Call a tool on the MCP server with the given arguments."
  def call_tool(client, tool_name, arguments \\ %{}, timeout \\ @call_timeout) do
    GenServer.call(client, {:call_tool, tool_name, arguments}, timeout)
  end

  @doc "Gracefully disconnect from the MCP server."
  def disconnect(client) do
    GenServer.stop(client, :normal)
  end

  # -- GenServer callbacks --

  @impl true
  def init(opts) do
    transport_type = Keyword.get(opts, :transport, :stdio)
    {transport_mod, transport_opts} = build_transport_opts(transport_type, opts)

    {:ok, transport_pid} = transport_mod.start_link([{:owner, self()} | transport_opts])

    state = %__MODULE__{
      transport_mod: transport_mod,
      transport_pid: transport_pid,
      next_id: 1,
      pending: %{},
      server_info: nil,
      initialized: false
    }

    # Send initialize request
    {id, state} = next_id(state)

    send_rpc(state, %{
      jsonrpc: "2.0",
      id: id,
      method: "initialize",
      params: %{
        protocolVersion: "2024-11-05",
        capabilities: %{},
        clientInfo: %{name: "aaasp-ex", version: "0.1.0"}
      }
    })

    state = register_pending(state, id, :initialize)

    {:ok, state}
  end

  @impl true
  def handle_call(:list_tools, from, state) do
    {id, state} = next_id(state)

    send_rpc(state, %{
      jsonrpc: "2.0",
      id: id,
      method: "tools/list",
      params: %{}
    })

    state = register_pending(state, id, {:list_tools, from})
    {:noreply, state}
  end

  def handle_call({:call_tool, name, arguments}, from, state) do
    {id, state} = next_id(state)

    send_rpc(state, %{
      jsonrpc: "2.0",
      id: id,
      method: "tools/call",
      params: %{name: name, arguments: arguments}
    })

    state = register_pending(state, id, {:call_tool, from})
    {:noreply, state}
  end

  @impl true
  def handle_info({:mcp_message, msg}, state) do
    {:noreply, handle_message(msg, state)}
  end

  def handle_info({:mcp_transport_closed, status}, state) do
    Logger.warning("[MCP] transport closed: #{inspect(status)}")

    for {_id, pending} <- state.pending do
      case pending do
        {:list_tools, from} -> GenServer.reply(from, {:error, :transport_closed})
        {:call_tool, from} -> GenServer.reply(from, {:error, :transport_closed})
        _ -> :ok
      end
    end

    {:stop, {:transport_closed, status}, %{state | pending: %{}}}
  end

  def handle_info(msg, state) do
    Logger.debug("[MCP] unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %{transport_mod: mod, transport_pid: pid}) when not is_nil(pid) do
    try do
      mod.stop(pid)
    catch
      :exit, _ -> :ok
    end

    :ok
  end

  def terminate(_reason, _state), do: :ok

  # -- Message handling --

  defp handle_message(%{"id" => id, "result" => result}, state) do
    {pending_value, remaining} = Map.pop(state.pending, id)
    state = %{state | pending: remaining}

    case pending_value do
      :initialize ->
        Logger.info("[MCP] initialized: #{inspect(result["serverInfo"])}")

        send_rpc(state, %{
          jsonrpc: "2.0",
          method: "notifications/initialized"
        })

        %{state | server_info: result, initialized: true}

      {:list_tools, from} ->
        tools = Map.get(result, "tools", [])
        GenServer.reply(from, {:ok, tools})
        state

      {:call_tool, from} ->
        content = Map.get(result, "content", [])

        text =
          content
          |> Enum.filter(&(&1["type"] == "text"))
          |> Enum.map_join("\n", & &1["text"])

        is_error = Map.get(result, "isError", false)

        if is_error do
          GenServer.reply(from, {:error, text})
        else
          GenServer.reply(from, {:ok, text})
        end

        state

      nil ->
        Logger.warning("[MCP] response for unknown id=#{id}")
        state
    end
  end

  defp handle_message(%{"id" => id, "error" => error}, state) do
    {pending_value, remaining} = Map.pop(state.pending, id)
    state = %{state | pending: remaining}

    case pending_value do
      nil ->
        Logger.warning("[MCP] error for unknown id=#{id}: #{inspect(error)}")
        state

      :initialize ->
        Logger.error("[MCP] initialization failed: #{inspect(error)}")
        state

      {_, from} ->
        GenServer.reply(from, {:error, error})
        state
    end
  end

  defp handle_message(%{"method" => method}, state) do
    Logger.debug("[MCP] notification: #{method}")
    state
  end

  defp handle_message(msg, state) do
    Logger.debug("[MCP] unhandled message: #{inspect(msg)}")
    state
  end

  # -- Helpers --

  defp next_id(state) do
    {state.next_id, %{state | next_id: state.next_id + 1}}
  end

  defp register_pending(state, id, value) do
    %{state | pending: Map.put(state.pending, id, value)}
  end

  defp send_rpc(state, message) do
    state.transport_mod.send_message(state.transport_pid, message)
  end

  defp build_transport_opts(:stdio, opts) do
    {AaaspEx.Mcp.Transport.Stdio, Keyword.take(opts, [:command, :args, :env])}
  end

  defp build_transport_opts(:sse, opts) do
    {AaaspEx.Mcp.Transport.Sse, Keyword.take(opts, [:url, :headers])}
  end
end
