# Xeba

A self-hosted Telegram AI companion with a private Phoenix LiveView console.
[Exiron](https://github.com/c2bw/exiron) handles Telegram connectivity and routing;
Xeba supplies conversation context, AI replies, and per-chat automation.

- Reply to routed commands and messages mentioning the configured bot name.
- Reply to text or captions answering a message Xeba sent, without requiring its name.
- Read photo and file captions, including album captions, as conversation text.
- Customize system prompts and context windows for each chat.
- Schedule autonomous messages or trigger them manually.
- Browse dated transcripts, token usage, and a searchable sticker bank.

Each chat's sticker bank uses Telegram's stable `file_unique_id` for deduplication
and keeps the latest observed `sticker_id` for sending. Older entries use identical
media bytes as a fallback; new observations can supply their missing stable ID.
Expand **Telegram file ID** on a sticker card to inspect the full sendable ID.

Conversation history stays in PostgreSQL until you manually delete it. Recent
conversation context is sent to your configured AI provider when generating replies.

## Run locally

CI and Docker use Elixir 1.20.4 and Erlang/OTP 29.1.2. For local development,
install those versions, Git, and PostgreSQL (CI uses PostgreSQL 17). Exiron must be
reachable to receive Telegram messages.

From a checkout of this repository:

```sh
mix deps.get
cp .env.example .env
```

Edit `.env`: fill in the login credentials, PostgreSQL password, Exiron hook token,
and AI settings. Use shell-compatible assignments and quote values containing
spaces or shell metacharacters. Mix does not load this file automatically:

```sh
set -a
. ./.env
set +a
export POSTGRES_HOST=localhost

mix setup
mix phx.server
```

Open [localhost:4000](http://localhost:4000) and sign in with `XEBA_AUTH_USERNAME`
and `XEBA_AUTH_PASSWORD`. `mix setup` creates and migrates the database and builds
assets. Change `POSTGRES_HOST` if PostgreSQL runs on another host.

The web console can start without Telegram/AI settings; its connection indicator
will show that the poller is disabled. Development defaults to `admin` / `xeba`
when login variables are unset; explicitly blank values are rejected.

## Connect Telegram through Exiron

In Exiron's configuration dashboard:

1. Configure your Telegram bot and the chats it should serve.
2. Create a dedicated hook for Xeba and copy its worker token to `EXIRON_HOOK_TOKEN`.
3. Route a command such as `/ai` to that hook and enable the route for your chats.
   Enable outbound pushes for chats that should receive autonomous messages.
4. Save and activate the configuration, then start Xeba. Confirm the hook is
   connected and send `/ai hello` in a configured chat.

Set `EXIRON_BASE_URL` to the Exiron server's base URL and `TELEGRAM_BOT_NAME` to the
name Xeba should recognize in conversation. Xeba also listens for chat messages to
build context and collect stickers. Use one running Xeba instance per hook; keep
`EXIRON_CLIENT_ID` stable across restarts and use separate hooks for independent
instances. See the [Exiron setup guide](https://github.com/c2bw/exiron#2-configure-a-bot-and-a-hook)
for bot, route, and chat configuration.

Media captions enter conversation history and can trigger replies through a routed
request or a bot mention, just like text messages. Xeba reads the caption text;
it does not analyze the attached image, audio, video, or file contents.

Replies to Xeba's messages are matched using Telegram delivery IDs stored in
PostgreSQL, including autonomous messages, split text, and sticker replies. This
works across Xeba restarts and does not require Exiron's `followups` routing option.
The replied-to message is included in AI context even outside the recent-history
window. Replies from bots and references to other chats, services, or topics do not
trigger this behavior.

Use an Exiron server with delivery receipt support (introduced in commit
`04198ba`); Xeba's `mix.lock` pins a compatible SDK. Run Xeba's database migrations
before starting the updated application. Messages sent before receipt tracking was
enabled cannot be matched retrospectively. Incoming replies need text or a media
caption, and Xeba must receive them through Exiron's listener; keep the hook's
chat routing and access configuration in place. See
[reply tracking upgrades](docs/operations.md#reply-tracking-upgrade) for upgrade
order and troubleshooting.

## Configuration

[.env.example](.env.example) is the complete configuration template. Restart Xeba
after changing environment variables.

| Variables | Purpose |
| --- | --- |
| `EXIRON_BASE_URL`, `EXIRON_HOOK_TOKEN` | Exiron connection; required for Telegram processing. |
| `EXIRON_CLIENT_ID` | Stable worker identity; defaults to `xeba`. |
| `TELEGRAM_BOT_NAME` | Name recognized in chat; defaults to `xeba`. |
| `AI_API_KEY`, `AI_MODEL` | AI credentials and model; required for replies. |
| `AI_ENDPOINT` | Optional OpenAI-compatible Chat Completions base URL. |
| `XEBA_AUTH_USERNAME`, `XEBA_AUTH_PASSWORD` | Console credentials; required and non-blank in production. |
| `POSTGRES_HOST`, `POSTGRES_PORT`, `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB` | Database connection settings. |
| `POSTGRES_TEST_DB`, `POSTGRES_POOL_SIZE` | Test database name and connection pool size. |
| `DATABASE_URL` | Production-only alternative to the individual PostgreSQL settings. |
| `SECRET_KEY_BASE`, `PHX_HOST` | Production session secret and public HTTPS hostname. |
| `TZ` | Prompt timezone; Compose defaults to `Europe/Rome`. Transcripts use `Europe/Rome`. |

Leave `AI_ENDPOINT` empty to select a native provider with a model such as
`cerebras:gpt-oss-120b`. For an OpenAI-compatible endpoint, set
`AI_ENDPOINT=https://api.cerebras.ai/v1` and use the raw model ID, such as
`AI_MODEL=gpt-oss-120b`.

Console sessions expire after 60 days. Logout revokes the session; changing
credentials invalidates existing sessions. Login allows five attempts per minute
per peer IP per instance, including successful attempts. Clients behind the same
reverse proxy share that limit.

## Deploy with Docker

Compose starts Xeba only. Provision PostgreSQL and create its database first;
set `POSTGRES_HOST` to a hostname reachable from the container, or use `DATABASE_URL`.
The template's `postgres` hostname requires a database on a shared Docker network;
`localhost` inside the container refers to Xeba itself.

Copy `.env.example` to `.env` and fill in the secrets and service addresses. Set
`PHX_HOST` to the public hostname without a scheme or port. Generate a
`SECRET_KEY_BASE` with `openssl rand -hex 64` or `mix phx.gen.secret`.

To choose a database name, set `POSTGRES_DB` in `.env` (default: `xeba_dev`):

```dotenv
POSTGRES_DB=xeba_production
```

Create that database on your PostgreSQL server before running migrations. Changing
this setting selects a database; it does not rename or copy an existing one.
If `DATABASE_URL` is non-empty, its database name takes precedence over `POSTGRES_DB`.

```sh
docker compose build xeba
docker compose run --rm --no-deps xeba /app/bin/migrate
docker compose up -d xeba
```

To use a published image, replace the build command with
`docker compose pull xeba`. The default image is `ghcr.io/c2bw/xeba:latest`;
it becomes available after a successful GitHub `main` build and requires package
access. For repeatable deployments, set Compose's `image` to the CI tag
`ghcr.io/c2bw/xeba:sha-<full-commit-sha>` and use that same image for migration
and startup. See [upgrading Xeba](docs/operations.md#upgrading-xeba) before updating
an existing deployment.

Production requires HTTPS through a reverse proxy with WebSocket support.
Compose binds port 4000 to the host's loopback interface. Follow the
[operations guide](docs/operations.md#https-and-reverse-proxy) to configure TLS,
forwarded headers, backups, and recovery.

| Endpoint | Meaning |
| --- | --- |
| `/health/live` | HTTP 200 when the web app is responding. |
| `/health/ready` | HTTP 200 when a database query succeeds; HTTP 503 otherwise. |

These endpoints are public, support HEAD, and bypass HTTPS redirects for local
probes. Readiness does not check Telegram or AI availability. The Docker health
check uses readiness; an unhealthy status alone does not trigger Docker's restart
policy. Set `PHX_SERVER=true` when starting the image directly outside Compose.

## Development

```sh
mix precommit          # Compile with warnings as errors, format, and run tests
MIX_ENV=test mix assets.build
```

Tests use a separate PostgreSQL database and disable external Telegram/AI calls.
They use `POSTGRES_TEST_DB` (default `xeba_test`), not `POSTGRES_DB` or
`DATABASE_URL`; the configured PostgreSQL user must be able to create it, or the
database must already exist. Never point `POSTGRES_TEST_DB` at a live database.
GitHub CI checks pull requests targeting `main` and pushes to `main`; only a
successful push to `main` publishes the amd64/arm64 image to GHCR.

For delivery recovery, text-replacement undo, and manual data deletion, see the
[operations guide](docs/operations.md).

## License

[MIT](LICENSE).
