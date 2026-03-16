defmodule AaaspEx.Mcp.ClientTest do
  use ExUnit.Case, async: true

  alias AaaspEx.Mcp.Client

  @fake_server """
  import sys, json

  def send(msg):
      sys.stdout.write(json.dumps(msg) + "\\n")
      sys.stdout.flush()

  for line in sys.stdin:
      msg = json.loads(line.strip())
      if msg.get("method") == "initialize":
          send({"jsonrpc": "2.0", "id": msg["id"], "result": {
              "protocolVersion": "2024-11-05",
              "serverInfo": {"name": "test-server", "version": "0.1.0"},
              "capabilities": {"tools": {}}
          }})
      elif msg.get("method") == "notifications/initialized":
          pass
      elif msg.get("method") == "tools/list":
          send({"jsonrpc": "2.0", "id": msg["id"], "result": {
              "tools": [
                  {"name": "greet", "description": "Say hello",
                   "inputSchema": {"type": "object",
                                   "properties": {"name": {"type": "string"}},
                                   "required": ["name"]}}
              ]
          }})
      elif msg.get("method") == "tools/call":
          name = msg["params"].get("arguments", {}).get("name", "world")
          send({"jsonrpc": "2.0", "id": msg["id"], "result": {
              "content": [{"type": "text", "text": "Hello, " + name + "!"}]
          }})
  """

  describe "start_link/1" do
    test "connects to a stdio MCP server and can list/call tools" do
      {:ok, client} = Client.start_link(
        command: "python3",
        args: ["-c", @fake_server]
      )

      # Wait for the init handshake
      Process.sleep(500)

      # List tools
      assert {:ok, tools} = Client.list_tools(client)
      assert [%{"name" => "greet", "description" => "Say hello"}] = tools

      # Call a tool
      assert {:ok, "Hello, Claude!"} = Client.call_tool(client, "greet", %{"name" => "Claude"})

      # Clean disconnect
      Client.disconnect(client)
    end

    test "handles multiple sequential tool calls" do
      {:ok, client} = Client.start_link(
        command: "python3",
        args: ["-c", @fake_server]
      )

      Process.sleep(500)

      assert {:ok, "Hello, Alice!"} = Client.call_tool(client, "greet", %{"name" => "Alice"})
      assert {:ok, "Hello, Bob!"} = Client.call_tool(client, "greet", %{"name" => "Bob"})

      Client.disconnect(client)
    end
  end
end
