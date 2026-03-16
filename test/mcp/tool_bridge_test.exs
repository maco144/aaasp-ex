defmodule AaaspEx.Mcp.ToolBridgeTest do
  use ExUnit.Case, async: true

  alias AaaspEx.Mcp.ToolBridge

  describe "to_tools/3" do
    test "converts MCP tool definitions to tool maps" do
      mcp_tools = [
        %{
          "name" => "dimensional_analysis",
          "description" => "Check dimensional consistency of an equation",
          "inputSchema" => %{
            "type" => "object",
            "properties" => %{
              "equation" => %{"type" => "string", "description" => "The equation to check"}
            },
            "required" => ["equation"]
          }
        },
        %{
          "name" => "verify_limits",
          "description" => "Verify limiting cases",
          "inputSchema" => %{
            "type" => "object",
            "properties" => %{
              "expression" => %{"type" => "string"}
            }
          }
        }
      ]

      tools = ToolBridge.to_tools(mcp_tools, self())

      assert length(tools) == 2

      [tool1, tool2] = tools
      assert tool1.name == "dimensional_analysis"
      assert tool1.description == "Check dimensional consistency of an equation"
      assert is_function(tool1.function, 2)
      assert tool2.name == "verify_limits"
    end

    test "applies prefix to tool names" do
      mcp_tools = [
        %{
          "name" => "search",
          "description" => "Search something",
          "inputSchema" => %{"type" => "object", "properties" => %{}}
        }
      ]

      tools = ToolBridge.to_tools(mcp_tools, self(), prefix: "physics_")

      assert [tool] = tools
      assert tool.name == "physics_search"
    end

    test "handles tools with no inputSchema" do
      mcp_tools = [
        %{"name" => "no_args", "description" => "A tool with no parameters"}
      ]

      tools = ToolBridge.to_tools(mcp_tools, self())

      assert [tool] = tools
      assert tool.name == "no_args"
      assert tool.parameters_schema == %{"type" => "object", "properties" => %{}}
    end

    test "handles tools with no description" do
      mcp_tools = [
        %{
          "name" => "mystery",
          "inputSchema" => %{"type" => "object", "properties" => %{}}
        }
      ]

      tools = ToolBridge.to_tools(mcp_tools, self())

      assert [tool] = tools
      assert tool.description == "MCP tool: mystery"
    end
  end
end
