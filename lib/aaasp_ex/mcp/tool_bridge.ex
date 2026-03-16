defmodule AaaspEx.Mcp.ToolBridge do
  @moduledoc """
  Converts MCP tool definitions into the tool map format used by ReqLLM/Jido.

  Each MCP tool becomes a map with `:name`, `:description`, `:parameters_schema`,
  and `:function` keys — the same shape that `Jido.Action.to_tool/2` produces.
  The `:function` callback invokes the tool on the remote MCP server via
  `AaaspEx.Mcp.Client.call_tool/3`.

  ## Example

      {:ok, client} = AaaspEx.Mcp.Client.start_link(command: "npx", args: ["-y", "my-server"])
      {:ok, mcp_tools} = AaaspEx.Mcp.Client.list_tools(client)
      tools = AaaspEx.Mcp.ToolBridge.to_tools(mcp_tools, client)
      # tools is a list of tool maps — pass directly to JidoReAct
  """

  require Logger

  @doc """
  Convert a list of MCP tool definitions to tool maps compatible with
  the Jido/ReqLLM tool format.

  Each tool's function callback will call the MCP server via the given client pid.
  Tool names are optionally prefixed to avoid collisions with built-in tools.

  ## Options

    * `:prefix` — string prefix for tool names (e.g., `"physics_"`)
    * `:timeout` — timeout for tool calls in ms (default: 60_000)
  """
  @spec to_tools([map()], pid(), keyword()) :: [map()]
  def to_tools(mcp_tools, client_pid, opts \\ []) do
    prefix = Keyword.get(opts, :prefix, "")
    timeout = Keyword.get(opts, :timeout, 60_000)

    Enum.map(mcp_tools, fn tool ->
      mcp_name = tool["name"]
      bridged_name = prefix <> mcp_name
      description = tool["description"] || "MCP tool: #{mcp_name}"
      input_schema = tool["inputSchema"] || %{"type" => "object", "properties" => %{}}

      %{
        name: bridged_name,
        description: description,
        parameters_schema: input_schema,
        function: fn params, _context ->
          Logger.debug("[MCP.ToolBridge] calling #{mcp_name} with #{inspect(params)}")

          # Convert atom keys to string keys for the MCP server
          arguments = stringify_keys(params)

          case AaaspEx.Mcp.Client.call_tool(client_pid, mcp_name, arguments, timeout) do
            {:ok, result} ->
              {:ok, result}

            {:error, reason} ->
              Logger.warning("[MCP.ToolBridge] #{mcp_name} failed: #{inspect(reason)}")
              {:error, inspect(reason)}
          end
        end
      }
    end)
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  defp stringify_keys(other), do: other
end
