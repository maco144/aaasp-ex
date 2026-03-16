defmodule AaaspEx.Mcp.Transport do
  @moduledoc """
  Behaviour for MCP message transports.

  A transport handles the low-level sending and receiving of JSON-RPC
  messages between the MCP client and server. Two implementations
  are provided:

    * `AaaspEx.Mcp.Transport.Stdio` — spawns a local process, communicates via stdin/stdout
    * `AaaspEx.Mcp.Transport.Sse` — connects to a remote HTTP+SSE endpoint
  """

  @type t :: pid()

  @doc "Start the transport and return its pid."
  @callback start_link(opts :: keyword()) :: {:ok, pid()} | {:error, term()}

  @doc "Send a JSON-RPC message (map) to the server."
  @callback send_message(transport :: pid(), message :: map()) :: :ok | {:error, term()}

  @doc "Stop the transport."
  @callback stop(transport :: pid()) :: :ok
end
