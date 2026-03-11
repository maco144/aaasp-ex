defmodule AaaspEx.Tools.Actions.HttpRequest do
  @moduledoc """
  Jido.Action — make an HTTP GET or POST request to an external API.

  Uses Finch for HTTP. Configure the Finch pool via:

      config :aaasp_ex, :finch_pool, MyApp.Finch
  """

  use Jido.Action,
    name: "http_request",
    description: "Make an HTTP GET or POST request to an external API",
    schema: [
      url:     [type: :string, required: true,  doc: "The URL to request"],
      method:  [type: :string, required: false, doc: "HTTP method: GET or POST (default GET)"],
      body:    [type: :map,    required: false, doc: "JSON body for POST requests"],
      headers: [type: :map,    required: false, doc: "Additional request headers"]
    ]

  require Logger

  @timeout_ms 30_000

  @impl true
  def run(%{url: url} = params, _context) do
    method  = params |> Map.get(:method, "GET") |> String.upcase() |> parse_method()
    body    = Map.get(params, :body)
    headers = build_headers(Map.get(params, :headers, %{}), body)
    encoded = if body, do: Jason.encode!(body), else: nil
    pool    = Application.get_env(:aaasp_ex, :finch_pool, AaaspEx.Finch)

    Logger.info("[AaaspEx.HttpRequest] #{method} #{url}")

    case Finch.request(Finch.build(method, url, headers, encoded), pool, receive_timeout: @timeout_ms) do
      {:ok, %Finch.Response{status: status, body: resp_body}} when status in 200..299 ->
        parsed = case Jason.decode(resp_body) do
          {:ok, json} -> json
          _           -> resp_body
        end
        {:ok, %{status: status, body: parsed}}

      {:ok, %Finch.Response{status: status, body: resp_body}} ->
        {:error, "HTTP #{status}: #{String.slice(resp_body, 0, 500)}"}

      {:error, reason} ->
        {:error, "Request failed: #{inspect(reason)}"}
    end
  end

  @doc "Returns a ReqLLM.Tool with a live callback for use in ReAct loops."
  def to_tool(tool_context \\ %{}) do
    ReqLLM.Tool.new!(%{
      name: "http_request",
      description: "Make an HTTP GET or POST request to an external API",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "url"     => %{"type" => "string", "description" => "The URL to request"},
          "method"  => %{"type" => "string", "description" => "HTTP method: GET or POST (default GET)"},
          "body"    => %{"type" => "object", "description" => "JSON body for POST requests"},
          "headers" => %{"type" => "object", "description" => "Additional request headers as key-value pairs"}
        },
        "required" => ["url"]
      },
      callback: fn params ->
        args = %{
          url:     Map.get(params, "url"),
          method:  Map.get(params, "method", "GET"),
          body:    Map.get(params, "body"),
          headers: Map.get(params, "headers", %{})
        }

        case run(args, tool_context) do
          {:ok, result}    -> {:ok, Jason.encode!(result)}
          {:error, reason} -> {:error, reason}
        end
      end
    })
  end

  defp parse_method("POST"), do: :post
  defp parse_method(_),      do: :get

  defp build_headers(extra, body) do
    base  = [{"user-agent", "AaaspEx/1.0"}]
    ct    = if body, do: [{"content-type", "application/json"}], else: []
    extra = Enum.map(extra, fn {k, v} -> {to_string(k), to_string(v)} end)
    base ++ ct ++ extra
  end
end
