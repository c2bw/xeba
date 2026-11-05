defmodule Xeba.Conversations.DatabaseTextReplacement do
  use Ecto.Schema
  import Ecto.Changeset

  schema "database_text_replacements" do
    field :source_text, :string
    field :replacement_text, :string
    field :affected_rows, :integer
    field :snapshot, :map
    field :undone_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(replacement, attrs) do
    replacement
    |> cast(attrs, [:source_text, :replacement_text, :affected_rows, :snapshot], empty_values: [])
    |> validate_required([:source_text, :affected_rows, :snapshot])
    |> validate_number(:affected_rows, greater_than_or_equal_to: 0)
  end
end
