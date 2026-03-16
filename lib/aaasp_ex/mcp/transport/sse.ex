defmodule AaaspEx.Mcp.Transport.Sse do
  @moduledoc """
  MCP transport over HTTP + Server-Sent Events.

  Implements the MCP Streamable HTTP transport:
  1. Client sends JSON-RPC messages via HTTP POST to the server URL
  2. Server may respond inline (JSON) or open an SSE stream
  3. Standalone SSE stream receives server-initiated notifications

  Incoming messages are forwarded to the `owner` process as
  `{:mcp_message, map()}`.
  """

  @behaviour AaaspEx.Mcp.Transport

  use GenServer
  require Logger

  defstruct [:url, :owner, :headers, :sse_task, :sse_buffer]

  @impl AaaspEx.Mcp.Transport
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl AaaspEx.Mcp.Transport
  def send_message(transport, message) do
    GenServer.call(transport, {:send, message}, 30_000)
  end

  @impl AaaspEx.Mcp.Transport
  def stop(transport) do
    GenServer.stop(transport, :normal)
  end

  # -- GenServer --

  @impl true
  def init(opts) do
    url = Keyword.fetch!(opts, :url)
    owner = Keyword.fetch!(opts, :owner)
    headers = Keyword.get(opts, :headers, [])

    state = %__MODULE__{
      url: url,
      owner: owner,
      headers: headers,
      sse_task: nil,
      sse_buffer: ""
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:send, message}, _from, state) do
    json = Jason.encode!(message)
    pool = Application.get_env(:aaasp_ex, :finch_pool, AaaspEx.Finch)

    req_headers =
      [{"content-type", "application/json"}, {"accept", "text/event-stream, application/json"}]
      ++ state.headers

    request = Finch.build(:post, state.url, req_headers, json)

    case Finch.request(request, pool, receive_timeout: 30_000) do
      {:ok, %Finch.Response{status: status, headers: resp_headers, body: body}}
      when status in 200..299 ->
        content_type = get_header(resp_headers, "content-type")
        handle_response(content_type, body, state)
        {:reply, :ok, maybe_start_sse_listener(state, resp_headers)}

      {:ok, %Finch.Response{status: status, body: body}} ->
        Logger.warning("[MCP.SSE] POST failed: HTTP #{status} #{String.slice(body, 0, 200)}")
        {:reply, {:error, {:http_error, status, body}}, state}

      {:error, reason} ->
        Logger.warning("[MCP.SSE] POST failed: #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info({:sse_events, events}, state) do
    for event <- events do
      case event do
        %{data: data} when data != "" ->
          case Jason.decode(data) do
            {:ok, msg} -> send(state.owner, {:mcp_message, msg})
            {:error, _} -> Logger.debug("[MCP.SSE] non-JSON SSE data: #{inspect(data)}")
          end

        _ ->
          :ok
      end
    end

    {:noreply, state}
  end

  def handle_info({:sse_closed, reason}, state) do
    Logger.info("[MCP.SSE] SSE stream closed: #{inspect(reason)}")
    send(state.owner, {:mcp_transport_closed, reason})
    {:noreply, %{state | sse_task: nil}}
  end

  def handle_info({ref, _result}, state) when is_reference(ref) do
    # Task completion message — ignore
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.debug("[MCP.SSE] unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.sse_task do
      Task.shutdown(state.sse_task, :brutal_kill)
    end

    :ok
  end

  # -- Response handling --

  defp handle_response(ct, body, state) when is_binary(ct) do
    cond do
      String.contains?(ct, "text/event-stream") ->
        parse_sse_body(body, state.owner)

      String.contains?(ct, "application/json") ->
        case Jason.decode(body) do
          {:ok, msg} -> send(state.owner, {:mcp_message, msg})
          {:error, _} -> Logger.debug("[MCP.SSE] non-JSON response body")
        end

      true ->
        Logger.debug("[MCP.SSE] unexpected content-type: #{ct}")
    end
  end

  defp handle_response(nil, body, state) do
    # No content-type, try JSON
    case Jason.decode(body) do
      {:ok, msg} -> send(state.owner, {:mcp_message, msg})
      {:error, _} -> Logger.debug("[MCP.SSE] could not parse response")
    end
  end

  defp parse_sse_body(body, owner) do
    {events, _buffer} = ServerSentEvents.parse(body)

    for event <- events do
      case event do
        %{data: data} when data != "" ->
          case Jason.decode(data) do
            {:ok, msg} -> send(owner, {:mcp_message, msg})
            _ -> :ok
          end

        _ ->
          :ok
      end
    end
  end

  # Start a background SSE listener if the server indicates one
  defp maybe_start_sse_listener(state, _resp_headers) do
    # For now, rely on inline POST responses. A full implementation
    # would open a persistent GET /sse stream here for server-initiated
    # notifications. This is sufficient for request/response MCP usage.
    state
  end

  defp get_header(headers, name) do
    case List.keyfind(headers, name, 0) do
      {_, value} -> value
      nil -> nil
    end
  end
end
