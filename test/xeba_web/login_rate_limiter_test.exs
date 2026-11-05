defmodule XebaWeb.LoginRateLimiterTest do
  use ExUnit.Case, async: true

  alias XebaWeb.LoginRateLimiter

  test "limits attempts per client and permits attempts after the window expires" do
    clock = start_supervised!({Agent, fn -> 0 end})

    limiter =
      start_supervised!(
        {LoginRateLimiter, name: {:global, make_ref()}, clock: fn -> Agent.get(clock, & &1) end}
      )

    for _ <- 1..5, do: assert(:ok = LoginRateLimiter.check(:client, limiter))
    assert {:error, 60} = LoginRateLimiter.check(:client, limiter)
    assert :ok = LoginRateLimiter.check(:another_client, limiter)

    Agent.update(clock, fn _ -> 59_500 end)
    assert {:error, 1} = LoginRateLimiter.check(:client, limiter)

    Agent.update(clock, fn _ -> 60_000 end)
    assert :ok = LoginRateLimiter.check(:client, limiter)
  end
end
