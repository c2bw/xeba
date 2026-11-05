defmodule Xeba.Repo.Migrations.CreateDatabaseTextReplacements do
  use Ecto.Migration

  def change do
    create table(:database_text_replacements) do
      add :source_text, :text, null: false
      add :replacement_text, :text, null: false
      add :affected_rows, :integer, null: false
      add :snapshot, :map, null: false
      add :undone_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:database_text_replacements, [:undone_at, :inserted_at])
  end
end
