defmodule AaaspEx.Executor.JidoReAct do
  @moduledoc """
  ReAct (Reason + Act) executor using Jido tools and ReqLLM.

  Runs a tool-calling loop via `ReqLLM.generate_text` until the model
  signals `:stop` or `max_iterations` is reached. Tools are Jido.Action
  modules resolved from `agent_def.tools` via `AaaspEx.Tools.Registry`.

  Set `agent_def.executor = "jido_react"` to use this backend.

  ## model_config keys

  | Key              | Default     |
  |------------------|-------------|
  | `provider`       | `"anthropic"` |
  | `model`          | provider default |
  | `max_iterations` | `10`        |
  | `temperature`    | `0.7`       |
  | `max_tokens`     | `4096`      |
  """

  @behaviour AaaspEx.Executor

  require Logger
  alias AaaspEx.Tools.Registry
  alias AaaspEx.Mcp.ServerPool

  @default_max_iterations 10

  @impl AaaspEx.Executor
  def execute(ctx, agent_def, api_key, opts \\ []) do
    model_cfg  = agent_def.model_config || %{}
    provider   = Map.get(model_cfg, "provider", "anthropic")
    model      = Map.get(model_cfg, "model", default_model(provider))
    model_spec = "#{provider}:#{model}"
    max_iter   = Map.get(model_cfg, "max_iterations", @default_max_iterations)

    tool_context = %{api_key: api_key, tenant_id: ctx.tenant_id}
    registry_tools = Registry.resolve_as_tools(agent_def.tools || [], tool_context)

    # Connect to MCP servers and merge their tools
    {mcp_tools, mcp_cleanup} = resolve_mcp_tools(agent_def.mcp_servers || [])
    tools = registry_tools ++ mcp_tools

    req_opts = [
      api_key:     api_key,
      tools:       tools,
      temperature: Map.get(model_cfg, "temperature", 0.7),
      max_tokens:  Map.get(model_cfg, "max_tokens", 4096)
    ]

    initial_context = AaaspEx.Executor.build_messages(agent_def.system_prompt, ctx.prompt, opts)

    tool_names = Enum.map(tools, & &1.name)
    Logger.info("[AaaspEx.JidoReAct] #{model_spec} tools=#{inspect(tool_names)} run=#{ctx.id}")

    result = react_loop(model_spec, initial_context, tools, req_opts, 0, max_iter, nil)

    # Clean up MCP connections after run completes
    mcp_cleanup.()

    result
  end

  defp react_loop(_model, _context, _tools, _opts, iter, max, _usage) when iter >= max do
    Logger.warning("[AaaspEx.JidoReAct] max_iterations=#{max} reached, stopping")
    {:error, :max_iterations_exceeded}
  end

  defp react_loop(model_spec, context, tools, opts, iter, max, usage_acc) do
    case ReqLLM.generate_text(model_spec, context, opts) do
      {:ok, %{finish_reason: :stop} = response} ->
        {:ok, extract_text(response), normalize_usage(merge_usage(usage_acc, response.usage))}

      {:ok, %{finish_reason: :tool_calls, message: msg, context: next_ctx} = response} ->
        Logger.debug("[AaaspEx.JidoReAct] iter=#{iter} tool_calls=#{length(msg.tool_calls || [])}")
        updated_ctx = ReqLLM.Context.execute_and_append_tools(next_ctx, msg.tool_calls, tools)
        react_loop(model_spec, updated_ctx, tools, opts, iter + 1, max, merge_usage(usage_acc, response.usage))

      {:ok, response} ->
        Logger.warning("[AaaspEx.JidoReAct] unexpected finish_reason=#{inspect(response.finish_reason)}")
        {:ok, extract_text(response), normalize_usage(merge_usage(usage_acc, response.usage))}

      {:error, reason} ->
        Logger.error("[AaaspEx.JidoReAct] LLM call failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp extract_text(%{message: %{content: parts}}) when is_list(parts) do
    parts
    |> Enum.filter(&(&1.type == :text))
    |> Enum.map_join("", & &1.text)
  end

  defp extract_text(%{message: %{content: content}}) when is_binary(content), do: content
  defp extract_text(_), do: ""

  defp normalize_usage(nil), do: nil

  defp normalize_usage(usage) do
    %{
      "input_tokens"  => Map.get(usage, :input_tokens, 0),
      "output_tokens" => Map.get(usage, :output_tokens, 0)
    }
  end

  defp merge_usage(nil, b), do: b
  defp merge_usage(a, nil), do: a

  defp merge_usage(a, b) do
    %{
      input_tokens:  Map.get(a, :input_tokens, 0)  + Map.get(b, :input_tokens, 0),
      output_tokens: Map.get(a, :output_tokens, 0) + Map.get(b, :output_tokens, 0)
    }
  end

  defp resolve_mcp_tools([]), do: {[], fn -> :ok end}

  defp resolve_mcp_tools(server_specs) do
    case ServerPool.connect_and_resolve(server_specs) do
      {:ok, tools, cleanup} ->
        Logger.info("[AaaspEx.JidoReAct] MCP: #{length(tools)} tools from #{length(server_specs)} server(s)")
        {tools, cleanup}

      {:error, reason} ->
        Logger.warning("[AaaspEx.JidoReAct] MCP connection failed: #{inspect(reason)}")
        {[], fn -> :ok end}
    end
  end

  defp default_model("anthropic"), do: "claude-haiku-4-5-20251001"
  defp default_model("openai"),    do: "gpt-4o-mini"
  defp default_model("groq"),      do: "llama-3.1-8b-instant"
  defp default_model(_),           do: "gpt-4o-mini"
end
