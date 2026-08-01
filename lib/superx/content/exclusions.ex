defmodule SuperX.Content.Exclusions do
  @moduledoc """
  Content categories that can be kept out of the library.

  These are keyword matches, not a classifier. That is a deliberate
  trade: the cost of a false positive is one fewer post out of hundreds
  of thousands, and the cost of a false negative is a user publishing
  something in the shape of a political rant. A cheap, legible rule that
  errs toward exclusion beats an accurate one nobody can audit.

  Applied two ways. On `Inspiration` they are filters the user turns on
  and off, because someone researching crypto content legitimately wants
  to see it. On template selection they are always applied — the writer
  borrows *shape*, and none of these shapes are ones an account should
  find itself imitating by accident.
  """

  @categories [
    %{
      key: "crypto",
      label: "Crypto / Web3",
      pattern:
        "(crypto|bitcoin|ethereum|web3|\\mnft\\M|altcoin|defi|solana|blockchain|memecoin|airdrop|hodl)"
    },
    %{
      key: "politics",
      label: "Politics",
      pattern:
        "(trump|biden|maga|election|senate|congress|republican|democrat|parliament|prime minister|white house|impeach|deportation)"
    },
    %{
      key: "nsfw",
      label: "NSFW / Adult",
      pattern: "(onlyfans|\\mnsfw\\M|\\mporn|nudes|sex tape|escort|camgirl)"
    },
    %{
      key: "promo",
      label: "Self-promo / Spam",
      pattern:
        "(link in bio|\\mdm me\\M|check out my|sign up now|limited time|promo code|discount code|affiliate link|retweet to win|follow me for|giveaway)"
    }
  ]

  @doc "Every category, for rendering the filter list."
  def categories, do: @categories

  @doc "The keys of every category, i.e. exclude everything."
  def all_keys, do: Enum.map(@categories, & &1.key)

  @doc """
  A single regex matching any of `keys`, or nil when none are given.

  Combining them into one alternation keeps this to a single `!~*` per
  query rather than one per category.
  """
  def pattern_for(keys) when is_list(keys) do
    patterns =
      @categories
      |> Enum.filter(&(&1.key in keys))
      |> Enum.map(& &1.pattern)

    case patterns do
      [] -> nil
      list -> Enum.join(list, "|")
    end
  end

  def pattern_for(_), do: nil
end
