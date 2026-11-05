defmodule Xeba.Repo.Migrations.RemoveCerebrasRateLimitsFromExchanges do
  use Ecto.Migration

  def change do
    alter table(:exchanges) do
      remove :remaining_tokens_minute, :bigint
      remove :remaining_requests_day, :bigint
    end
  end
end
