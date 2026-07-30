defmodule SuperX.AI do
  @moduledoc """
  Thin client over the Anthropic Messages API plus embeddings.

  Prompts live in `SuperX.AI.Prompts`; this module only handles transport,
  structured-output extraction, and error shape.
  """

  require Logger

  @anthropic_url "https://api.anthropic.com/v1/messages"
  @anthropic_version "2023-06-01"
  @voyage_url "https://api.voyageai.com/v1/embeddings"

  @doc """
  Sends a completion request and returns the assistant's text.

  Options:

    * `:model` — defaults to the configured writer model
    * `:system` — system prompt
    * `:max_tokens` — defaults to 2048
    * `:temperature`
  """
  @spec complete(String.t() | [map()], keyword()) :: {:ok, String.t()} | {:error, term()}
  def complete(prompt, opts \\ [])

  def complete(prompt, opts) when is_binary(prompt) do
    complete([%{role: "user", content: prompt}], opts)
  end

  def complete(messages, opts) when is_list(messages) do
    body =
      %{
        model: opts[:model] || config(:writer_model),
        max_tokens: opts[:max_tokens] || 2048,
        messages: messages
      }
      |> maybe_put(:system, opts[:system])
      |> maybe_put(:temperature, opts[:temperature])

    case request(body) do
      {:ok, %{"content" => content}} -> {:ok, extract_text(content)}
      {:ok, other} -> {:error, {:unexpected_response, other}}
      error -> error
    end
  end

  @doc """
  Asks for a JSON object matching `schema` and returns it decoded.

  Uses a forced tool call rather than prompt-level "reply with JSON",
  because the API then validates the shape and the model retries itself
  instead of us parsing prose.
  """
  @spec structured(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def structured(prompt, schema, opts \\ []) do
    tool = %{
      name: "respond",
      description: opts[:tool_description] || "Return the structured result.",
      input_schema: schema
    }

    body =
      %{
        model: opts[:model] || config(:writer_model),
        max_tokens: opts[:max_tokens] || 2048,
        messages: [%{role: "user", content: prompt}],
        tools: [tool],
        tool_choice: %{type: "tool", name: "respond"}
      }
      |> maybe_put(:system, opts[:system])
      |> maybe_put(:temperature, opts[:temperature])

    case request(body) do
      {:ok, %{"content" => content}} ->
        case Enum.find(content, &(&1["type"] == "tool_use")) do
          %{"input" => input} -> {:ok, input}
          _ -> {:error, {:no_tool_use, content}}
        end

      {:ok, other} ->
        {:error, {:unexpected_response, other}}

      error ->
        error
    end
  end

  @doc """
  Sends a request body through untouched and returns the full response.

  Needed by the tool-use loop in `SuperX.Ask`, which has to see
  `stop_reason` and the raw content blocks to decide whether to run tools
  and go round again. Everything else should use `complete/2` or
  `structured/3`.
  """
  @spec raw(map()) :: {:ok, map()} | {:error, term()}
  def raw(body) when is_map(body), do: request(body)

  @doc """
  Embeds a list of texts, returning vectors in the same order.

  `input_type` should be `"document"` when embedding corpus posts and
  `"query"` when embedding a search — Voyage encodes them differently and
  mixing the two measurably degrades retrieval.
  """
  @spec embed([String.t()], keyword()) :: {:ok, [[float()]]} | {:error, term()}
  def embed(texts, opts \\ []) when is_list(texts) do
    cond do
      texts == [] ->
        {:ok, []}

      is_nil(voyage_key()) ->
        {:error, :embeddings_not_configured}

      true ->
        body = %{
          model: config(:embedding_model),
          input: texts,
          input_type: opts[:input_type] || "document",
          output_dimension: config(:embedding_dimensions)
        }

        req =
          Req.new(
            url: @voyage_url,
            json: body,
            auth: {:bearer, voyage_key()},
            receive_timeout: 60_000,
            retry: :transient,
            max_retries: 2
          )

        case Req.post(req) do
          {:ok, %{status: 200, body: %{"data" => data}}} ->
            {:ok, data |> Enum.sort_by(& &1["index"]) |> Enum.map(& &1["embedding"])}

          {:ok, %{status: status, body: body}} ->
            {:error, {:http_error, status, body}}

          {:error, reason} ->
            {:error, {:transport_error, reason}}
        end
    end
  end

  @doc "Embeds a single text."
  def embed_one(text, opts \\ []) do
    case embed([text], opts) do
      {:ok, [vector]} -> {:ok, vector}
      {:ok, []} -> {:error, :empty_response}
      error -> error
    end
  end

  @doc "Whether an Anthropic key is present."
  def configured?, do: is_binary(anthropic_key()) and anthropic_key() != ""

  @doc "Whether embeddings are available; retrieval degrades to FTS without them."
  def embeddings_configured?, do: is_binary(voyage_key()) and voyage_key() != ""

  def writer_model, do: config(:writer_model)
  def utility_model, do: config(:utility_model)

  # --- Internals -----------------------------------------------------------

  defp request(body) do
    if configured?() do
      req =
        Req.new(
          url: @anthropic_url,
          json: body,
          headers: [
            {"x-api-key", anthropic_key()},
            {"anthropic-version", @anthropic_version}
          ],
          # Generation can legitimately take a while; the caller is a job.
          receive_timeout: 120_000,
          retry: :transient,
          max_retries: 2
        )

      case Req.post(req) do
        {:ok, %{status: 200, body: body}} ->
          {:ok, body}

        {:ok, %{status: 429, body: body}} ->
          {:error, {:rate_limited, body}}

        {:ok, %{status: status, body: body}} ->
          Logger.warning("Anthropic returned #{status}: #{inspect(body)}")
          {:error, {:http_error, status, body}}

        {:error, reason} ->
          {:error, {:transport_error, reason}}
      end
    else
      {:error, :not_configured}
    end
  end

  defp extract_text(content) do
    content
    |> Enum.filter(&(&1["type"] == "text"))
    |> Enum.map_join("", & &1["text"])
    |> String.trim()
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp config(key), do: Application.get_env(:superx, __MODULE__, [])[key]
  defp anthropic_key, do: config(:anthropic_api_key)
  defp voyage_key, do: config(:voyage_api_key)
end
