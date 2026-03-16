defmodule AaaspEx.Mcp.ServerPool do
  @moduledoc """
  Manages a set of MCP server connections and resolves their tools as
  `ReqLLM.Tool.t()` structs ready for use in executor loops.

  This is the main integration point — callers pass a list of server specs
  and get back a flat list of tools plus a cleanup function.

  ## Example

      servers = [
        %{command: "npx", args: ["-y", "get-physics-done"], prefix: "physics_"},
        %{command: "python", args: ["-m", "my_mcp_server"]}
      ]

      {:ok, tools, cleanup_fn} = AaaspEx.Mcp.ServerPool.connect_and_resolve(servers)
      # tools is [ReqLLM.Tool.t()] — use in ReAct loop
      # call cleanup_fn.() when done to disconnect all servers
  """

  alias AaaspEx.Mcp.{Client, ToolBridge}
  require Logger

  @type server_spec :: %{
          command: String.t(),
          args: [String.t()],
          env: [{String.t(), String.t()}],
          prefix: String.t()
        }

  @doc """
  Connect to all MCP servers, discover their tools, and return bridged
  `ReqLLM.Tool.t()` structs.

  Returns `{:ok, tools, cleanup_fn}` where `cleanup_fn` is a zero-arity
  function that disconnects all servers. The caller is responsible for
  invoking cleanup when the run completes.

  On partial failure, servers that connected successfully are still returned
  and the failed servers are logged.
  """
  @spec connect_and_resolve([server_spec()], keyword()) ::
          {:ok, [ReqLLM.Tool.t()], (-> :ok)} | {:error, term()}
  def connect_and_resolve(server_specs, opts \\ []) when is_list(server_specs) do
    timeout = Keyword.get(opts, :timeout, 60_000)

    results =
      server_specs
      |> Task.async_stream(
        fn spec -> connect_one(spec, timeout) end,
        timeout: timeout + 5_000,
        on_timeout: :kill_task
      )
      |> Enum.to_list()

    {successes, failures} =
      Enum.split_with(results, fn
        {:ok, {:ok, _}} -> true
        _ -> false
      end)

    for failure <- failures do
      Logger.warning("[MCP.ServerPool] server failed to connect: #{inspect(failure)}")
    end

    connected =
      Enum.map(successes, fn {:ok, {:ok, data}} -> data end)

    all_tools = Enum.flat_map(connected, fn %{tools: tools} -> tools end)
    pids = Enum.map(connected, fn %{pid: pid} -> pid end)

    cleanup = fn ->
      Enum.each(pids, fn pid ->
        try do
          Client.disconnect(pid)
        catch
          :exit, _ -> :ok
        end
      end)

      :ok
    end

    {:ok, all_tools, cleanup}
  end

  defp connect_one(spec, timeout) do
    command = Map.fetch!(spec, :command)
    args = Map.get(spec, :args, [])
    env = Map.get(spec, :env, [])
    prefix = Map.get(spec, :prefix, "")

    with {:ok, pid} <- Client.start_link(command: command, args: args, env: env),
         # Give the server a moment to initialize
         :ok <- wait_for_init(pid, timeout),
         {:ok, mcp_tools} <- Client.list_tools(pid, timeout) do
      tools = ToolBridge.to_tools(mcp_tools, pid, prefix: prefix, timeout: timeout)

      Logger.info(
        "[MCP.ServerPool] connected to #{command} #{Enum.join(args, " ")} — " <>
          "#{length(tools)} tools discovered"
      )

      {:ok, %{pid: pid, tools: tools, command: command}}
    end
  end

  # Poll for initialization (the MCP handshake is async via Port messages)
  defp wait_for_init(_pid, timeout) when timeout <= 0, do: {:error, :init_timeout}

  defp wait_for_init(pid, _timeout) do
    # Try listing tools — if the server isn't ready, it'll fail or timeout
    # The Client GenServer queues calls, so this effectively waits for init
    Process.sleep(100)

    if Process.alive?(pid) do
      :ok
    else
      {:error, :server_crashed}
    end
  end
end
