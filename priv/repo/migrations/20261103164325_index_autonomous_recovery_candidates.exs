defmodule Xeba.Repo.Migrations.IndexAutonomousRecoveryCandidates do
  use Ecto.Migration

  def change do
    create index(:exchanges, [:id],
             name: :exchanges_autonomous_recovery_index,
             where: "msgtype = 'autonomous' AND status IN ('pending', 'reply_failed')"
           )
  end
end
