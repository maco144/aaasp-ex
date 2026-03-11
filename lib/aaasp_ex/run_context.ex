defmodule AaaspEx.RunContext do
  @moduledoc """
  Lightweight struct passed to executor backends describing the current run.

  This is intentionally free of Ecto and database concerns. Applications
  that store runs in a database should map their schema to a RunContext
  before dispatching via `AaaspEx.Executor`.
  """

  @type t :: %__MODULE__{
          id:        String.t(),
          prompt:    String.t(),
          tenant_id: String.t() | nil,
          metadata:  map()
        }

  defstruct id: nil,
            prompt: "",
            tenant_id: nil,
            metadata: %{}

  @doc """
  Build a RunContext from a plain map. `:id` and `:prompt` are required.
  """
  @spec from_map(map()) :: t()
  def from_map(attrs) when is_map(attrs) do
    %__MODULE__{
      id:        Map.get(attrs, :id)        || Map.get(attrs, "id"),
      prompt:    Map.get(attrs, :prompt)    || Map.get(attrs, "prompt", ""),
      tenant_id: Map.get(attrs, :tenant_id) || Map.get(attrs, "tenant_id"),
      metadata:  Map.get(attrs, :metadata)  || Map.get(attrs, "metadata", %{})
    }
  end
end
