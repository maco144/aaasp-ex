defmodule AaaspEx do
  @moduledoc """
  AaaspEx — open-source Elixir agent execution engine.

  Provides:
  - `AaaspEx.RunContext` — lightweight struct describing a run (prompt, tenant, metadata)
  - `AaaspEx.AgentDef` — agent configuration (model, tools, system prompt)
  - `AaaspEx.Executor` — behaviour + dispatcher for execution backends
  - `AaaspEx.Executor.JidoDirect` — single-turn LLM execution via ReqLLM
  - `AaaspEx.Executor.JidoReAct` — ReAct (Reason+Act) tool-calling loop
  - `AaaspEx.Tools.Registry` — maps tool name strings to Jido.Action modules
  - `AaaspEx.Tools.Actions.*` — built-in tool implementations

  ## Configuration

      config :aaasp_ex, :finch_pool, MyApp.Finch

  The `:finch_pool` option tells the built-in tools which Finch pool to use
  for HTTP requests. If not set, defaults to `AaaspEx.Finch` — make sure
  a Finch process with that name is started in your supervision tree.
  """
end
