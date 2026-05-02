# aaasp-ex

Open-source Elixir agent execution engine. Provides the executor and tool-calling layer that powers [AAASP](https://aaasp.ai) — a multi-tenant Agent-as-a-Service platform.

Built on [Jido](https://github.com/agentjido/jido) and [ReqLLM](https://hex.pm/packages/req_llm). Licensed under the [Rising Sun License v1.0](./LICENSE).

---

## What's included

| Module | Description |
|--------|-------------|
| `AaaspEx.Executor` | Behaviour + dispatcher for execution backends |
| `AaaspEx.Executor.JidoDirect` | Single-turn LLM call via ReqLLM |
| `AaaspEx.Executor.JidoReAct` | ReAct (Reason + Act) tool-calling loop |
| `AaaspEx.Tools.Registry` | Maps tool name strings to `Jido.Action` modules |
| `AaaspEx.Tools.Actions.SearchWeb` | Web search tool (pluggable provider) |
| `AaaspEx.Tools.Actions.ReadUrl` | Fetch and extract text from a URL |
| `AaaspEx.Tools.Actions.HttpRequest` | Generic HTTP GET/POST tool |
| `AaaspEx.RunContext` | Lightweight run descriptor (no Ecto dependency) |
| `AaaspEx.AgentDef` | Agent configuration struct |

---

## Installation

```elixir
# mix.exs
def deps do
  [
    {:aaasp_ex, "~> 0.1.0"}
  ]
end
```

Configure the Finch pool used by built-in HTTP tools:

```elixir
# config/config.exs
config :aaasp_ex, :finch_pool, MyApp.Finch
```

Make sure a Finch process with that name is started in your supervision tree. If you skip this config, the tools default to `AaaspEx.Finch` and you'll need to start that yourself.

---

## Usage

### Single-turn execution

```elixir
ctx = %AaaspEx.RunContext{
  id:        "run-123",
  prompt:    "Summarise the Jido README",
  tenant_id: "tenant-abc"
}

agent_def = %AaaspEx.AgentDef{
  executor:      "jido_direct",
  system_prompt: "You are a helpful assistant.",
  model_config:  %{"provider" => "anthropic", "model" => "claude-haiku-4-5-20251001"},
  tools:         []
}

{:ok, result, usage} = AaaspEx.Executor.dispatch(ctx, agent_def, api_key)
```

### ReAct tool-calling loop

```elixir
agent_def = %AaaspEx.AgentDef{
  executor:     "jido_react",
  model_config: %{"provider" => "anthropic", "max_iterations" => 5},
  tools:        ["search_web", "read_url"]
}

{:ok, result, usage} = AaaspEx.Executor.dispatch(ctx, agent_def, api_key)
```

### Streaming

```elixir
AaaspEx.Executor.stream_dispatch(ctx, agent_def, api_key, fn chunk ->
  IO.write(chunk)
end)
```

---

## Custom backends

Implement the `AaaspEx.Executor` behaviour and register via config:

```elixir
config :aaasp_ex, :executors, %{
  "my_executor" => MyApp.Executors.Custom
}
```

Your module receives `(ctx, agent_def, api_key, opts)` and returns
`{:ok, result, usage} | {:error, reason}`.

---

## Custom tools

Implement a `Jido.Action` and register via config:

```elixir
config :aaasp_ex, :tools, %{
  "my_tool" => MyApp.Tools.MyTool
}
```

Tools must expose a `to_tool/1` function returning a `ReqLLM.Tool` struct
with a callback for use in the ReAct loop.

---

## Model providers

ReqLLM supports multiple providers out of the box. Set `provider` in `model_config`:

| Provider | Example model |
|----------|---------------|
| `"anthropic"` | `"claude-haiku-4-5-20251001"` |
| `"openai"` | `"gpt-4o-mini"` |
| `"groq"` | `"llama-3.1-8b-instant"` |
| `"deepseek"` | `"deepseek-chat"` |
| `"together"` | `"meta-llama/Meta-Llama-3.1-8B-Instruct-Turbo"` |

---

## License

[Rising Sun License v1.0](./LICENSE)

Free for personal use. Commercial deployments must integrate with the Nous network. Enterprise licenses available at [aaasp.ai](https://aaasp.ai).
