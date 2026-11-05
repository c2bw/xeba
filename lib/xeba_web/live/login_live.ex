defmodule XebaWeb.LoginLive do
  use XebaWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    form = to_form(%{"username" => "", "password" => ""}, as: :auth)

    {:ok,
     socket
     |> assign(:page_title, "Log in")
     |> assign(:form, form)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="grid min-h-[calc(100vh-3.25rem)] place-items-center px-4 py-10">
        <div class="w-full max-w-sm rounded-2xl border border-white/10 bg-[#0a1512]/90 p-5 shadow-2xl shadow-black/25 backdrop-blur sm:p-6">
          <div class="mb-5">
            <div class="mb-4 grid size-10 place-items-center rounded-xl border border-emerald-300/20 bg-emerald-300/10">
              <.icon name="hero-lock-closed" class="size-5 text-emerald-300" />
            </div>
            <p class="text-[0.65rem] font-semibold uppercase tracking-[0.18em] text-emerald-300/70">
              Restricted workspace
            </p>
            <h1 class="mt-1 text-xl font-semibold text-white">Open the control room</h1>
            <p class="mt-1.5 text-xs leading-5 text-stone-500">
              Monitor conversations, inspect context, and tune autonomous replies.
            </p>
          </div>

          <.form
            for={@form}
            id="single-user-login-form"
            action={~p"/log-in"}
            method="post"
            class="space-y-3"
          >
            <.input
              field={@form[:username]}
              type="text"
              label="Username"
              autocomplete="username"
              required
            />
            <.input
              field={@form[:password]}
              type="password"
              label="Password"
              autocomplete="current-password"
              required
            />
            <button
              id="single-user-login-submit"
              type="submit"
              phx-disable-with="Signing in…"
              class="inline-flex w-full items-center justify-center gap-2 rounded-lg bg-emerald-300 px-4 py-2.5 text-sm font-semibold text-emerald-950 transition hover:bg-emerald-200 active:scale-[0.99]"
            >
              Log in <.icon name="hero-arrow-right" class="size-4" />
            </button>
          </.form>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
