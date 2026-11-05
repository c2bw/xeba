defmodule Xeba.Repo.Migrations.AddTokensUsedAtToExchanges do
  use Ecto.Migration

  def change do
    alter table(:exchanges) do
      add :tokens_used_at, :utc_datetime_usec
    end

    create index(:exchanges, [:tokens_used_at])
  end
end
