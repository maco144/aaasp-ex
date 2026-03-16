defmodule AaaspEx.AgentDef do
  @moduledoc """
  Lightweight struct representing an agent's configuration.

  Used by executors to determine model, tools, system prompt, and execution
  parameters. Applications that use AaaspEx can build this from their own
  schema types before dispatching.
  """

  @type mcp_server :: %{
          command: String.t(),
          args: [String.t()],
          env: [{String.t(), String.t()}],
          prefix: String.t()
        }

  @type t :: %__MODULE__{
          executor:      String.t(),
          system_prompt: String.t() | nil,
          model_config:  map(),
          tools:         [String.t()],
          mcp_servers:   [mcp_server()]
        }

  defstruct executor: "jido_direct",
            system_prompt: nil,
            model_config: %{},
            tools: [],
            mcp_servers: []

  @doc """
  Build an AgentDef from a plain map. All keys optional.
  """
  @spec from_map(map()) :: t()
  def from_map(attrs) when is_map(attrs) do
    %__MODULE__{
      executor:      Map.get(attrs, :executor)      || Map.get(attrs, "executor", "jido_direct"),
      system_prompt: Map.get(attrs, :system_prompt) || Map.get(attrs, "system_prompt"),
      model_config:  Map.get(attrs, :model_config)  || Map.get(attrs, "model_config", %{}),
      tools:         Map.get(attrs, :tools)          || Map.get(attrs, "tools", []),
      mcp_servers:   Map.get(attrs, :mcp_servers)    || Map.get(attrs, "mcp_servers", [])
    }
  end
end
