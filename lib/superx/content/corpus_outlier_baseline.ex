defmodule SuperX.Content.CorpusOutlierBaseline do
  @moduledoc """
  The cached corpus median for one follower-count band.

  Inspiration reads far more often than the corpus changes, so these ten
  rows keep the corpus-derived benchmark on the write path rather than
  making every search aggregate the whole library.
  """

  use Ecto.Schema

  @primary_key {:follower_bucket, :integer, autogenerate: false}
  schema "corpus_outlier_baselines" do
    field :median_engagement_score, :float
    field :sample_size, :integer
  end
end
