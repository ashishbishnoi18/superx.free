defmodule SuperX.Articles.Writer do
  @moduledoc """
  Drafts and extends articles in the connected account's learned voice.

  A composition claims its credit before the model call and refunds any
  failure. The returned prose is not persisted here: the editor remains
  the point where a person decides what belongs in their draft.
  """

  alias SuperX.{AI, Billing, Content}
  alias SuperX.AI.Prompts
  alias SuperX.Accounts.{User, XAccount}
  alias SuperX.Content.Voice

  @credit_cost 1

  @doc "Composes a new draft or a continuation without saving it."
  def compose(%User{} = user, %XAccount{} = account, mode, attrs)
      when mode in [:draft, :extend] do
    with :ok <- validate_request(mode, attrs),
         {:ok, voice} <- Content.get_or_create_voice_profile(account),
         {:ok, _balance} <- claim_credit(user) do
      case write(account, voice, mode, attrs) do
        {:ok, result} ->
          {:ok, result}

        {:error, reason} ->
          # A provider failure should not turn a blank editor into a bill.
          Billing.refund_credits(user, @credit_cost, ref_type: "article")
          {:error, reason}
      end
    end
  end

  @doc false
  def credit_cost, do: @credit_cost

  defp claim_credit(user) do
    case Billing.spend_credits(user, @credit_cost, "generation", ref_type: "article") do
      {:ok, balance} -> {:ok, balance}
      {:error, :quota_exceeded, details} -> {:error, :quota_exceeded, details}
      {:error, reason} -> {:error, reason}
    end
  end

  defp write(account, voice, mode, attrs) do
    examples = Voice.examples(account, voice)
    prompt = prompt(mode, attrs, examples)

    case AI.structured(prompt, Prompts.article_schema(mode),
           system: Prompts.article_writer_system(voice, account),
           model: AI.writer_model(),
           temperature: 0.8,
           # Long-form output and reasoning share this budget. A post-sized
           # allowance can finish thinking before it has written the body.
           max_tokens: 8000,
           tool_description: "Return the article prose."
         ) do
      {:ok, result} -> normalise_result(mode, attrs, result)
      {:error, reason} -> {:error, reason}
    end
  end

  defp prompt(:draft, attrs, examples) do
    Prompts.draft_article(value(attrs, :instruction), examples)
  end

  defp prompt(:extend, attrs, examples) do
    Prompts.extend_article(
      value(attrs, :title),
      value(attrs, :body),
      value(attrs, :instruction),
      examples
    )
  end

  defp normalise_result(:draft, attrs, %{"title" => title, "body" => body})
       when is_binary(title) and is_binary(body) do
    title = if blank?(value(attrs, :title)), do: String.trim(title), else: value(attrs, :title)
    body = String.trim(body)

    if blank?(title) or blank?(body) do
      {:error, :empty_generation}
    else
      {:ok, %{title: title, body: body}}
    end
  end

  defp normalise_result(:extend, attrs, %{"body" => continuation})
       when is_binary(continuation) do
    continuation = String.trim(continuation)

    if blank?(continuation) do
      {:error, :empty_generation}
    else
      body = String.trim_trailing(value(attrs, :body)) <> "\n\n" <> continuation
      {:ok, %{title: value(attrs, :title), body: body}}
    end
  end

  defp normalise_result(_mode, _attrs, result), do: {:error, {:unexpected_response, result}}

  defp validate_request(:draft, attrs) do
    if blank?(value(attrs, :instruction)), do: {:error, :missing_brief}, else: :ok
  end

  defp validate_request(:extend, attrs) do
    if blank?(value(attrs, :body)), do: {:error, :empty_article}, else: :ok
  end

  defp value(attrs, key) do
    Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key)) || ""
  end

  defp blank?(value), do: not is_binary(value) or String.trim(value) == ""
end
