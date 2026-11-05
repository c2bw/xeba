defmodule XebaWeb.AuthConfigTest do
  use ExUnit.Case, async: false

  setup do
    variables = ~w(XEBA_AUTH_USERNAME XEBA_AUTH_PASSWORD SECRET_KEY_BASE)
    previous = Map.new(variables, &{&1, System.get_env(&1)})

    on_exit(fn ->
      for {key, value} <- previous do
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end
    end)

    System.put_env("SECRET_KEY_BASE", String.duplicate("a", 64))
    :ok
  end

  test "production rejects missing and blank credentials" do
    for variable <- ~w(XEBA_AUTH_USERNAME XEBA_AUTH_PASSWORD), value <- [nil, "", " \t"] do
      System.put_env("XEBA_AUTH_USERNAME", "operator")
      System.put_env("XEBA_AUTH_PASSWORD", "configured-password")
      if value, do: System.put_env(variable, value), else: System.delete_env(variable)

      assert_raise RuntimeError, ~r/#{variable} must be set and non-blank/, fn ->
        Config.Reader.read!("config/runtime.exs", env: :prod, target: :host)
      end
    end
  end

  test "production uses explicitly configured credentials" do
    System.put_env("XEBA_AUTH_USERNAME", "operator")
    System.put_env("XEBA_AUTH_PASSWORD", "configured-password")
    config = Config.Reader.read!("config/runtime.exs", env: :prod, target: :host)

    assert config[:xeba][XebaWeb.UserAuth] == [
             username: "operator",
             password: "configured-password"
           ]
  end
end
