defmodule AaaspEx.Mcp.Client do
  @moduledoc """
  MCP (Model Context Protocol) client for connecting to external tool servers.

  Manages the lifecycle of an MCP server connection over stdio transport.
  Handles the JSON-RPC 2.0 protocol, initialization handshake, tool discovery,
  and tool invocation.

  ## Usage

      {:ok, client} = AaaspEx.Mcp.Client.start_link(
        command: "npx",
        args: ["-y", "some-mcp-server"]
      )

      {:ok, tools} = AaaspEx.Mcp.Client.list_tools(client)
      {:ok, result} = AaaspEx.Mcp.Client.call_tool(client, "tool_name", %{"arg" => "value"})

      AaaspEx.Mcp.Client.disconnect(client)
  """

  use GenServer
  require Logger

  @call_timeout 60_000

  defstruct [
    :port,
    :command,
    :args,
    :env,
    :next_id,
    :pending,
    :buffer,
    :server_info,
    :initialized
  ]

  # -- Public API --

  @doc """
  Start an MCP client and connect to the server.

  ## Options

    * `:command` — executable to spawn (required)
    * `:args` — list of command arguments (default: `[]`)
    * `:env` — list of `{key, value}` env vars for the spawned process (default: `[]`)
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
    command = Keyword.fetch!(opts, :command)
    args = Keyword.get(opts, :args, [])
    env = Keyword.get(opts, :env, [])

    port_opts = [
      :binary,
      :exit_status,
      :use_stdio,
      {:args, args},
      {:env, Enum.map(env, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)},
      {:line, 1_048_576}
    ]

    port = Port.open({:spawn_executable, find_executable(command)}, port_opts)

    state = %__MODULE__{
      port: port,
      command: command,
      args: args,
      env: env,
      next_id: 1,
      pending: %{},
      buffer: "",
      server_info: nil,
      initialized: false
    }

    # Send initialize request
    {id, state} = next_id(state)

    send_jsonrpc(state.port, %{
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

    send_jsonrpc(state.port, %{
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

    send_jsonrpc(state.port, %{
      jsonrpc: "2.0",
      id: id,
      method: "tools/call",
      params: %{name: name, arguments: arguments}
    })

    state = register_pending(state, id, {:call_tool, from})
    {:noreply, state}
  end

  @impl true
  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) do
    case Jason.decode(line) do
      {:ok, msg} ->
        {:noreply, handle_message(msg, state)}

      {:error, _} ->
        Logger.debug("[MCP] non-JSON line from server: #{inspect(line)}")
        {:noreply, state}
    end
  end

  def handle_info({port, {:data, {:noeol, chunk}}}, %{port: port} = state) do
    {:noreply, %{state | buffer: state.buffer <> chunk}}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning("[MCP] server exited with status #{status}")

    # Reply to any pending callers with an error
    for {_id, pending} <- state.pending do
      case pending do
        {:list_tools, from} -> GenServer.reply(from, {:error, :server_exited})
        {:call_tool, from} -> GenServer.reply(from, {:error, :server_exited})
        _ -> :ok
      end
    end

    {:stop, {:server_exited, status}, %{state | pending: %{}}}
  end

  def handle_info(msg, state) do
    Logger.debug("[MCP] unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %{port: port} = _state) do
    if Port.info(port) do
      Port.close(port)
    end

    :ok
  end

  # -- Message handling --

  defp handle_message(%{"id" => id, "result" => result}, state) do
    {pending_value, remaining} = Map.pop(state.pending, id)
    state = %{state | pending: remaining}

    case pending_value do
      :initialize ->
        Logger.info("[MCP] initialized: #{inspect(result["serverInfo"])}")

        # Send initialized notification
        send_jsonrpc(state.port, %{
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

  # Notifications from server (no id) — log and ignore for now
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

  defp send_jsonrpc(port, message) do
    json = Jason.encode!(message)
    Port.command(port, json <> "\n")
  end

  defp find_executable(command) do
    case System.find_executable(command) do
      nil -> raise "MCP: executable not found: #{command}"
      path -> to_charlist(path)
    end
  end
end
