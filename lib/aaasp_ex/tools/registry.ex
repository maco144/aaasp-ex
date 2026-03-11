defmodule AaaspEx.Tools.Registry do
  @moduledoc """
  Maps tool name strings to Jido.Action modules.

  Built-in tools are registered here. Custom tools can be added via config:

      config :aaasp_ex, :tools, %{
        "my_tool" => MyApp.Tools.MyTool
      }

  Custom tools are merged with and take precedence over built-ins.
  """

  @builtins %{
    "search_web"   => AaaspEx.Tools.Actions.SearchWeb,
    "read_url"     => AaaspEx.Tools.Actions.ReadUrl,
    "http_request" => AaaspEx.Tools.Actions.HttpRequest
  }

  @doc """
  Resolve a list of tool name strings to Action modules.
  Unknown names are silently dropped.
  """
  @spec resolve([String.t()]) :: [module()]
  def resolve(names) when is_list(names) do
    registry = Map.merge(@builtins, Application.get_env(:aaasp_ex, :tools, %{}))

    Enum.flat_map(names, fn name ->
      case Map.get(registry, name) do
        nil    -> []
        module -> [module]
      end
    end)
  end

  def resolve(_), do: []

  @doc """
  Resolve tool names to ReqLLM.Tool structs with live callbacks.
  `tool_context` is threaded into each Action's `run/2` context map.
  """
  @spec resolve_as_tools([String.t()], map()) :: [ReqLLM.Tool.t()]
  def resolve_as_tools(names, tool_context \\ %{}) do
    names
    |> resolve()
    |> Enum.map(& &1.to_tool(tool_context))
  end

  @doc "List all registered tool names (built-ins + custom)."
  @spec all_names() :: [String.t()]
  def all_names do
    @builtins
    |> Map.merge(Application.get_env(:aaasp_ex, :tools, %{}))
    |> Map.keys()
  end

  @doc "List built-in tool names only."
  @spec builtin_names() :: [String.t()]
  def builtin_names, do: Map.keys(@builtins)
end
