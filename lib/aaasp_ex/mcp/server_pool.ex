defmodule AaaspEx.Mcp.ServerPool do
  @moduledoc """
  Manages a set of MCP server connections and resolves their tools as
  maps ready for use in executor loops.

  This is the main integration point — callers pass a list of server specs
  and get back a flat list of tools plus a cleanup function.

  ## Example

      servers = [
        %{transport: "stdio", command: "npx", args: ["-y", "get-physics-done"], prefix: "physics_"},
        %{transport: "sse", url: "https://mcp.example.com/mcp", prefix: "remote_"}
      ]

      {:ok, tools, cleanup_fn} = AaaspEx.Mcp.ServerPool.connect_and_resolve(servers)
      # tools is a list of tool maps — use in ReAct loop
      # call cleanup_fn.() when done to disconnect all servers
  """

  alias AaaspEx.Mcp.{Client, ToolBridge}
  require Logger

  @type server_spec :: %{
          optional(:transport) => String.t(),
          optional(:command) => String.t(),
          optional(:args) => [String.t()],
          optional(:env) => [{String.t(), String.t()}],
          optional(:url) => String.t(),
          optional(:headers) => [{String.t(), String.t()}],
          optional(:prefix) => String.t()
        }

  @doc """
  Connect to all MCP servers, discover their tools, and return bridged
  tool maps.

  Returns `{:ok, tools, cleanup_fn}` where `cleanup_fn` is a zero-arity
  function that disconnects all servers. The caller is responsible for
  invoking cleanup when the run completes.

  On partial failure, servers that connected successfully are still returned
  and the failed servers are logged.
  """
  @spec connect_and_resolve([server_spec()], keyword()) ::
          {:ok, [map()], (-> :ok)} | {:error, term()}
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
    transport = Map.get(spec, :transport, Map.get(spec, "transport", "stdio"))
    prefix = Map.get(spec, :prefix, Map.get(spec, "prefix", ""))

    client_opts = build_client_opts(transport, spec)

    with {:ok, pid} <- Client.start_link(client_opts),
         :ok <- wait_for_init(pid),
         {:ok, mcp_tools} <- Client.list_tools(pid, timeout) do
      tools = ToolBridge.to_tools(mcp_tools, pid, prefix: prefix, timeout: timeout)

      label = transport_label(transport, spec)

      Logger.info(
        "[MCP.ServerPool] connected to #{label} — #{length(tools)} tools discovered"
      )

      {:ok, %{pid: pid, tools: tools, label: label}}
    end
  end

  defp build_client_opts("sse", spec) do
    url = Map.get(spec, :url) || Map.fetch!(spec, "url")
    headers = Map.get(spec, :headers, Map.get(spec, "headers", []))

    [transport: :sse, url: url, headers: headers]
  end

  defp build_client_opts(_stdio, spec) do
    command = Map.get(spec, :command) || Map.fetch!(spec, "command")
    args = Map.get(spec, :args, Map.get(spec, "args", []))
    env = Map.get(spec, :env, Map.get(spec, "env", []))

    [transport: :stdio, command: command, args: args, env: env]
  end

  defp transport_label("sse", spec),
    do: "SSE #{Map.get(spec, :url) || Map.get(spec, "url", "?")}"

  defp transport_label(_, spec) do
    command = Map.get(spec, :command) || Map.get(spec, "command", "?")
    args = Map.get(spec, :args, Map.get(spec, "args", []))
    "#{command} #{Enum.join(args, " ")}"
  end

  defp wait_for_init(pid) do
    Process.sleep(100)

    if Process.alive?(pid) do
      :ok
    else
      {:error, :server_crashed}
    end
  end
end
