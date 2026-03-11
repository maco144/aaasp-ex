defmodule AaaspEx.Executor do
  @moduledoc """
  Behaviour and dispatcher for agent execution backends.

  Each backend implements `execute/4` and returns
  `{:ok, result, usage} | {:error, reason}`.

  The backend is selected from `agent_def.executor`. Defaults to `jido_direct`.

  ## Built-in backends

  - `"jido_direct"` (default) — single-turn LLM call via ReqLLM
  - `"jido_react"`            — ReAct loop with Jido tool calling

  ## Custom backends

  Implement this behaviour and register via the `:executors` config key:

      config :aaasp_ex, :executors, %{
        "my_executor" => MyApp.Executors.Custom
      }

  Custom executors are merged with and take precedence over built-ins.
  """

  alias AaaspEx.{RunContext, AgentDef}

  @type result :: {:ok, String.t(), map() | nil} | {:error, term()}

  @callback execute(
              ctx       :: RunContext.t(),
              agent_def :: AgentDef.t(),
              api_key   :: String.t() | nil,
              opts      :: keyword()
            ) :: result

  @doc """
  Streaming variant. Calls `publish_fn.(chunk_text)` for each token as it
  arrives, then returns the same `{:ok, full_result, usage} | {:error, reason}`
  as `execute/4`.

  Backends that don't implement this callback fall back to a single publish
  of the full result after completion.
  """
  @callback stream_execute(
              ctx        :: RunContext.t(),
              agent_def  :: AgentDef.t(),
              api_key    :: String.t() | nil,
              publish_fn :: (String.t() -> any()),
              opts       :: keyword()
            ) :: result

  @optional_callbacks stream_execute: 5

  @builtins %{
    "jido_direct" => AaaspEx.Executor.JidoDirect,
    "jido_react"  => AaaspEx.Executor.JidoReAct
  }

  @doc "Dispatch a run to the appropriate executor backend (non-streaming)."
  @spec dispatch(RunContext.t(), AgentDef.t(), String.t() | nil, keyword()) :: result
  def dispatch(ctx, agent_def, api_key, opts \\ []) do
    backend = resolve_backend(agent_def.executor)
    backend.execute(ctx, agent_def, api_key, opts)
  end

  @doc """
  Dispatch in streaming mode. `publish_fn` is called with each text chunk.
  Falls back to non-streaming for backends that don't implement `stream_execute/5`.
  """
  @spec stream_dispatch(RunContext.t(), AgentDef.t(), String.t() | nil, (String.t() -> any()), keyword()) :: result
  def stream_dispatch(ctx, agent_def, api_key, publish_fn, opts \\ []) do
    backend = resolve_backend(agent_def.executor)

    if function_exported?(backend, :stream_execute, 5) do
      backend.stream_execute(ctx, agent_def, api_key, publish_fn, opts)
    else
      case backend.execute(ctx, agent_def, api_key, opts) do
        {:ok, result, usage} ->
          publish_fn.(result)
          {:ok, result, usage}

        error ->
          error
      end
    end
  end

  @doc """
  Build the full LLM message list from system prompt, user prompt, and
  optional session context (`opts[:context_messages]`).

  Returns atom-keyed maps: `[%{role: "system", content: ...}, ...]`.
  """
  @spec build_messages(String.t() | nil, String.t(), keyword()) :: [map()]
  def build_messages(system_prompt, user_prompt, opts \\ []) do
    context = opts |> Keyword.get(:context_messages, []) |> normalize_messages()

    system =
      case system_prompt do
        s when s in [nil, ""] -> []
        s -> [%{role: "system", content: s}]
      end

    system ++ context ++ [%{role: "user", content: user_prompt}]
  end

  defp normalize_messages(messages) do
    Enum.map(messages, fn msg ->
      %{
        role:    to_string(Map.get(msg, "role") || Map.get(msg, :role) || "user"),
        content: to_string(Map.get(msg, "content") || Map.get(msg, :content) || "")
      }
    end)
  end

  defp resolve_backend(name) do
    custom = Application.get_env(:aaasp_ex, :executors, %{})
    Map.get(custom, name) || Map.get(@builtins, name) || AaaspEx.Executor.JidoDirect
  end
end
