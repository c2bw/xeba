defmodule Xeba.Repo do
  use Ecto.Repo,
    otp_app: :xeba,
    adapter: Ecto.Adapters.Postgres
end
