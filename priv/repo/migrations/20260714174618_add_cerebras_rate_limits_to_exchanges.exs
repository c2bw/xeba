defmodule Xeba.Repo.Migrations.AddCerebrasRateLimitsToExchanges do
  use Ecto.Migration

  def change do
    alter table(:exchanges) do
      add :remaining_tokens_minute, :bigint
      add :remaining_requests_day, :bigint
    end
  end
end
