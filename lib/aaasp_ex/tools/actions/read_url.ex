defmodule AaaspEx.Tools.Actions.ReadUrl do
  @moduledoc """
  Jido.Action — fetch and return the text content of a URL.

  Uses Finch for HTTP. Configure the Finch pool via:

      config :aaasp_ex, :finch_pool, MyApp.Finch

  If not set, defaults to `AaaspEx.Finch`.
  """

  use Jido.Action,
    name: "read_url",
    description: "Fetch the text content of a web page or URL",
    schema: [
      url:       [type: :string,  required: true,  doc: "The URL to fetch"],
      max_chars: [type: :integer, required: false, doc: "Maximum characters to return (default 4000)"]
    ]

  require Logger

  @default_max_chars 4_000
  @request_timeout_ms 15_000

  @impl true
  def run(%{url: url} = params, _context) do
    max_chars = Map.get(params, :max_chars, @default_max_chars)
    Logger.info("[AaaspEx.ReadUrl] fetching #{url}")

    headers = [
      {"user-agent", "Mozilla/5.0 (compatible; AaaspEx/1.0)"},
      {"accept", "text/html,text/plain,application/json"}
    ]

    request = Finch.build(:get, url, headers)
    pool    = Application.get_env(:aaasp_ex, :finch_pool, AaaspEx.Finch)

    case Finch.request(request, pool, receive_timeout: @request_timeout_ms) do
      {:ok, %Finch.Response{status: status, body: body}} when status in 200..299 ->
        text = extract_text(body, max_chars)
        {:ok, %{url: url, content: text, chars: String.length(text)}}

      {:ok, %Finch.Response{status: status}} ->
        {:error, "HTTP #{status} for #{url}"}

      {:error, reason} ->
        {:error, "Request failed: #{inspect(reason)}"}
    end
  end

  @doc "Returns a ReqLLM.Tool with a live callback for use in ReAct loops."
  def to_tool(tool_context \\ %{}) do
    ReqLLM.Tool.new!(%{
      name: "read_url",
      description: "Fetch the text content of a web page or URL",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "url"       => %{"type" => "string",  "description" => "The URL to fetch"},
          "max_chars" => %{"type" => "integer", "description" => "Maximum characters to return (default 4000)"}
        },
        "required" => ["url"]
      },
      callback: fn params ->
        url       = Map.get(params, "url")
        max_chars = Map.get(params, "max_chars", @default_max_chars)

        case run(%{url: url, max_chars: max_chars}, tool_context) do
          {:ok, result}    -> {:ok, Jason.encode!(result)}
          {:error, reason} -> {:error, reason}
        end
      end
    })
  end

  defp extract_text(body, max_chars) do
    body
    |> String.replace(~r/<script[^>]*>.*?<\/script>/si, " ")
    |> String.replace(~r/<style[^>]*>.*?<\/style>/si, " ")
    |> String.replace(~r/<[^>]+>/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, max_chars)
  end
end
