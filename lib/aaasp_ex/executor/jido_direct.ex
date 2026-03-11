defmodule AaaspEx.Executor.JidoDirect do
  @moduledoc """
  Single-turn LLM executor using ReqLLM.

  Makes a single `generate_text` call with no tool loop. Good for
  stateless, one-shot agent runs.

  Set `agent_def.executor = "jido_direct"` to use this backend (it is
  also the default when no executor is specified).

  ## model_config keys

  | Key           | Default                        |
  |---------------|--------------------------------|
  | `provider`    | `"anthropic"`                  |
  | `model`       | provider-specific default      |
  | `temperature` | `0.7`                          |
  | `max_tokens`  | `4096`                         |
  """

  @behaviour AaaspEx.Executor

  require Logger

  @impl AaaspEx.Executor
  def execute(ctx, agent_def, api_key, opts \\ []) do
    model_cfg  = agent_def.model_config || %{}
    provider   = Map.get(model_cfg, "provider", "anthropic")
    model      = Map.get(model_cfg, "model", default_model(provider))
    model_spec = "#{provider}:#{model}"
    messages   = AaaspEx.Executor.build_messages(agent_def.system_prompt, ctx.prompt, opts)

    req_opts = [
      api_key:     api_key,
      temperature: Map.get(model_cfg, "temperature", 0.7),
      max_tokens:  Map.get(model_cfg, "max_tokens", 4096)
    ]

    Logger.info("[AaaspEx.JidoDirect] #{model_spec} run=#{ctx.id}")

    case ReqLLM.generate_text(model_spec, messages, req_opts) do
      {:ok, response} ->
        {:ok, extract_text(response), normalize_usage(response.usage)}

      {:error, reason} ->
        Logger.error("[AaaspEx.JidoDirect] run=#{ctx.id} failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @impl AaaspEx.Executor
  def stream_execute(ctx, agent_def, api_key, publish_fn, opts \\ []) do
    model_cfg  = agent_def.model_config || %{}
    provider   = Map.get(model_cfg, "provider", "anthropic")
    model      = Map.get(model_cfg, "model", default_model(provider))
    model_spec = "#{provider}:#{model}"
    messages   = AaaspEx.Executor.build_messages(agent_def.system_prompt, ctx.prompt, opts)

    req_opts = [
      api_key:     api_key,
      temperature: Map.get(model_cfg, "temperature", 0.7),
      max_tokens:  Map.get(model_cfg, "max_tokens", 4096)
    ]

    Logger.info("[AaaspEx.JidoDirect] stream #{model_spec} run=#{ctx.id}")

    case ReqLLM.stream_text(model_spec, messages, req_opts) do
      {:ok, stream_response} ->
        full_text =
          stream_response
          |> ReqLLM.StreamResponse.tokens()
          |> Enum.reduce("", fn token, acc ->
            publish_fn.(token)
            acc <> token
          end)

        usage = ReqLLM.StreamResponse.usage(stream_response)
        {:ok, full_text, normalize_usage(usage)}

      {:error, reason} ->
        Logger.error("[AaaspEx.JidoDirect] stream failed run=#{ctx.id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp extract_text(%{message: %{content: parts}}) when is_list(parts) do
    parts
    |> Enum.filter(&(&1.type == :text))
    |> Enum.map_join("", & &1.text)
  end

  defp extract_text(%{message: %{content: content}}) when is_binary(content), do: content

  defp extract_text(response) do
    Logger.warning("[AaaspEx.JidoDirect] unexpected response shape: #{inspect(response)}")
    ""
  end

  defp normalize_usage(nil), do: nil

  defp normalize_usage(usage) do
    %{
      "input_tokens"  => Map.get(usage, :input_tokens, 0),
      "output_tokens" => Map.get(usage, :output_tokens, 0)
    }
  end

  defp default_model("anthropic"), do: "claude-haiku-4-5-20251001"
  defp default_model("openai"),    do: "gpt-4o-mini"
  defp default_model("deepseek"),  do: "deepseek-chat"
  defp default_model("groq"),      do: "llama-3.1-8b-instant"
  defp default_model("together"),  do: "meta-llama/Meta-Llama-3.1-8B-Instruct-Turbo"
  defp default_model(_),           do: "gpt-4o-mini"
end
