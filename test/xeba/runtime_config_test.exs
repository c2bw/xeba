defmodule Xeba.RuntimeConfigTest do
  use ExUnit.Case, async: false

  setup do
    variables = ~w(DATABASE_URL POSTGRES_HOST POSTGRES_PORT POSTGRES_USER
      POSTGRES_PASSWORD POSTGRES_DB POSTGRES_POOL_SIZE POOL_SIZE
      XEBA_AUTH_USERNAME XEBA_AUTH_PASSWORD SECRET_KEY_BASE)
    previous = Map.new(variables, &{&1, System.get_env(&1)})

    on_exit(fn ->
      for {key, value} <- previous do
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end
    end)

    System.put_env(%{
      "XEBA_AUTH_USERNAME" => "operator",
      "XEBA_AUTH_PASSWORD" => "test-password",
      "SECRET_KEY_BASE" => String.duplicate("a", 64),
      "POSTGRES_HOST" => "database.example",
      "POSTGRES_PORT" => "5433",
      "POSTGRES_USER" => "xeba-user",
      "POSTGRES_PASSWORD" => "password@with:/?#symbols",
      "POSTGRES_DB" => "xeba_production",
      "POSTGRES_POOL_SIZE" => "7",
      "POOL_SIZE" => "9"
    })

    :ok
  end

  test "missing or empty DATABASE_URL uses individual settings without URL interpolation" do
    for value <- [nil, ""] do
      if value, do: System.put_env("DATABASE_URL", value), else: System.delete_env("DATABASE_URL")
      config = repo_config()
      assert config[:hostname] == "database.example"
      assert config[:port] == 5433
      assert config[:username] == "xeba-user"
      assert config[:password] == "password@with:/?#symbols"
      assert config[:database] == "xeba_production"
      assert config[:pool_size] == 7
      refute Keyword.has_key?(config, :url)
    end
  end

  test "DATABASE_URL takes precedence and POOL_SIZE remains a supported fallback" do
    url = "ecto://user:password@url.example/xeba"
    System.put_env("DATABASE_URL", url)
    System.delete_env("POSTGRES_POOL_SIZE")
    config = repo_config()
    assert config[:url] == url
    assert config[:pool_size] == 9
    refute Keyword.has_key?(config, :hostname)
  end

  defp repo_config do
    Config.Reader.read!("config/runtime.exs", env: :prod, target: :host)[:xeba][Xeba.Repo]
  end
end
