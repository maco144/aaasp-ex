defmodule AaaspEx.Tools.Actions.SearchWeb do
  @moduledoc """
  Jido.Action — search the web for current information.

  By default returns a placeholder result. Wire to a real provider by
  setting `:search_provider` in the tool context or config:

      config :aaasp_ex, :search_provider, MyApp.SearchProvider

  A search provider is a module implementing `search/1` that returns
  `{:ok, results}` where `results` is a list of maps.
  """

  use Jido.Action,
    name: "search_web",
    description: "Search the web for current information on a topic or question",
    schema: [
      query: [type: :string, required: true, doc: "The search query"]
    ]

  require Logger

  @impl true
  def run(%{query: query}, context) do
    Logger.info("[AaaspEx.SearchWeb] query=#{inspect(query)}")

    provider = Map.get(context, :search_provider) ||
               Application.get_env(:aaasp_ex, :search_provider)

    if provider do
      provider.search(query)
    else
      {:ok, %{
        results: [],
        message: "Search not configured. Set config :aaasp_ex, :search_provider or pass :search_provider in tool context."
      }}
    end
  end

  @doc "Returns a ReqLLM.Tool with a live callback for use in ReAct loops."
  def to_tool(tool_context \\ %{}) do
    ReqLLM.Tool.new!(%{
      name: "search_web",
      description: "Search the web for current information on a topic or question",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "query" => %{"type" => "string", "description" => "The search query"}
        },
        "required" => ["query"]
      },
      callback: fn %{"query" => query} ->
        case run(%{query: query}, tool_context) do
          {:ok, result}    -> {:ok, Jason.encode!(result)}
          {:error, reason} -> {:error, inspect(reason)}
        end
      end
    })
  end
end
