# Operations

See the [README](../README.md) for installation, configuration, and deployment.

## Upgrading Xeba

Take a database backup and record the current image tag before upgrading. Select
the intended image in `docker-compose.yml`, then pull it and stop the existing
worker before changing its schema:

```sh
docker compose pull xeba
docker compose stop xeba
docker compose run --rm --no-deps xeba /app/bin/migrate
docker compose up -d --no-build xeba
docker compose ps xeba
docker compose logs --tail=100 xeba
```

For a source build, replace `docker compose pull xeba` with
`docker compose build xeba`. Stop if any command fails; start Xeba only after
migrations succeed. The default Compose configuration does not run migrations
automatically. The migration command uses the release image and the same
environment as Xeba; it does not create the PostgreSQL database.

Confirm readiness, HTTPS login, LiveView updates, and a Telegram reply. For reply
tracking, send a text reply without Xeba's name to a newly sent Xeba message,
restart Xeba, and repeat. Test autonomous delivery if enabled.

Switching back to an older image does not undo schema or data changes. Check
migration compatibility before rolling back; use the verified backup recovery
procedure below when data restoration is needed.

## HTTPS and reverse proxy

Set `PHX_HOST` to your public hostname. Production enforces HTTPS, sends HSTS,
and uses `Secure`, `HttpOnly`, `SameSite=Lax` session cookies. TLS terminates at
a trusted reverse proxy; Compose exposes Xeba only at `127.0.0.1:4000`.

Example Nginx configuration, with your own hostname and certificate paths:

```nginx
# In the http context:
map $http_upgrade $connection_upgrade {
    default upgrade;
    '' close;
}

server {
    listen 80;
    server_name xeba.example.com;
    return 301 https://xeba.example.com$request_uri;
}

server {
    listen 443 ssl;
    server_name xeba.example.com;
    ssl_certificate /etc/letsencrypt/live/xeba.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/xeba.example.com/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:4000;
        proxy_http_version 1.1;
        proxy_set_header Host xeba.example.com;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-For $remote_addr;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_read_timeout 60s;
    }
}
```

The proxy must overwrite `X-Forwarded-Proto`; expose Xeba's HTTP port only to
trusted infrastructure. For a containerized proxy, remove the published port
and connect both services to a private Docker network, using `http://xeba:4000`
as the upstream. Configure certificate renewal and verify LiveView connects over
WebSocket after deployment.

Only `/health/live` and `/health/ready` bypass HTTPS redirects. If login loops,
check the forwarded protocol and hostname. Login throttling uses the proxy's
peer IP; configure per-client limits at the ingress if needed.

## Database backup and restore

Use PostgreSQL client tools compatible with your server version. Run these on
the operator host or a client container; the Xeba image does not include them.
Set the standard PostgreSQL variables for the source database:

```sh
export PGHOST=your-database-host
export PGPORT=5432
export PGUSER=xeba
export PGDATABASE=xeba_production
export PGPASSFILE="$HOME/.pgpass"
chmod 600 "$PGPASSFILE"
```

Create the password file first in PostgreSQL's
`host:port:database:user:password` format, escaping colons and backslashes.
Include credentials for the maintenance and recovery databases used below.
For remote connections, configure `PGSSLMODE=verify-full` and your trusted CA.
The application's `POSTGRES_*` variables are not consumed by these tools.

Take backups regularly and before upgrades or manual deletion:

```sh
umask 077
backup_dir="$HOME/xeba-backups"
mkdir -p "$backup_dir"
backup_file="$backup_dir/xeba-$(date -u +%Y%m%dT%H%M%SZ).dump"
pg_dump --format=custom --no-owner --no-acl --file="$backup_file.partial" &&
    pg_restore --list "$backup_file.partial" > /dev/null &&
    mv "$backup_file.partial" "$backup_file"
```

Check command exit statuses. A `.partial` file is not a completed backup.
Protect dumps like the live database, keep an off-host copy, and back up secrets
separately. Dumps contain one database, not cluster-wide roles or tablespaces.
Recovery loses writes made after the snapshot unless you also have continuous
backups or point-in-time recovery.

Verify recovery into a **new, empty database**:

```sh
recovery_db=xeba_restore_check
createdb --maintenance-db=postgres "$recovery_db"
pg_restore --exit-on-error --single-transaction --no-owner --no-acl \
    --dbname="$recovery_db" "$backup_file"
psql --dbname="$recovery_db" --set=ON_ERROR_STOP=1 \
    --command='SELECT count(*) FROM schema_migrations; SELECT count(*) FROM exchanges;'
```

Use an account allowed to create the recovery database, or have it provisioned
first. Compare counts and representative records with the source snapshot;
listing the archive alone does not prove recovery works. Provision the intended
application role and review database permissions before use.

To recover the application:

1. Stop Xeba and any other worker using its Exiron hook to prevent writes and replies.
2. Preserve the current database; restore the backup into a separate database.
3. Point Xeba at the restored database. Generate a new `SECRET_KEY_BASE` so
   sessions restored from the backup cannot revive revoked sign-ins.
4. Run migrations with the intended image, then start Xeba as described in the README.
5. Check readiness, login, and Telegram connectivity. Watch for replayed messages.

Keep the old database until recovery is verified. Stop Xeba before switching
databases again. PostgreSQL references: [pg_dump](https://www.postgresql.org/docs/current/app-pgdump.html),
[pg_restore](https://www.postgresql.org/docs/current/app-pgrestore.html),
[password files](https://www.postgresql.org/docs/current/libpq-pgpass.html).

## Data retention

**History is retained until manually deleted.** Xeba does not prune messages,
media, expired session records, undo snapshots, or backups automatically.

For manual erasure, take a backup, stop Xeba, and review the affected records:

| Table | Contents |
| --- | --- |
| `exchanges` | Messages, replies, sender data, token usage, errors, sticker bytes, and delivery checkpoints |
| `outgoing_telegram_messages` | Confirmed outgoing Telegram message IDs, service/chat/topic identifiers, delivery parts, and parent exchange references |
| `chat_stickers` | Separately banked sticker bytes and metadata |
| `telegram_chats` | Chat names and identifiers |
| `autonomous_channel_settings` | Per-chat settings and prompts |
| `database_text_replacements` | Original text retained for undo |
| `sessions` | Hashed tokens, credential versions, and expiry times |

Editing a message does not erase copies in checkpoints, undo snapshots, sticker
records, backups, logs, Exiron, or AI-provider systems. Review those separately.
Deleting message identities can allow a replay to be processed again. Restart
Xeba after manual database edits and decide separately when to retire backups.

Deleting an `exchanges` row also deletes its `outgoing_telegram_messages` rows
through a database foreign key. Removing those outgoing identities prevents Xeba
from recognizing replies to the corresponding Telegram messages. Neither deletion
removes messages from Telegram or erases the separately stored sticker bank.

## Delivery failures and text replacement

Xeba runs up to four background jobs, one per chat, with a 100-job capacity and
a two-minute active-job timeout. Failed incoming work returns an error to the SDK
for retry. Saved responses and text/sticker checkpoints avoid regenerating replies
or resending confirmed parts. An acknowledgement lost after remote acceptance
still leaves an ambiguous outcome; delivery is not guaranteed exactly once.

Autonomous processing allows four total attempts, including interrupted
generation. Delivery errors schedule retries after 1, 2, and 4 seconds. Recovery
checks unfinished work at startup and every 30 seconds, preserves retry deadlines,
and queues behind live work for the same chat. It reuses a saved response, or
regenerates from the saved prompt if no response was stored. Paused chats are not
sent autonomous messages; queue admission failures do not consume attempts.

Exhausted generation interruptions become `failed`; unfinished deliveries remain
`reply_failed` for review. Historical autonomous rows without an attempt counter
require manual review. A manual **Send now** confirmation means the queue accepted
the job, not that Telegram has received it.

Text replacement changes display names, usernames, conversation text, and errors;
it preserves protocol identifiers. Pending delivery or retry blocks replacement
and undo. Undo restores changed fields only when their current values still match
the replacement; conflicting edits cancel the transaction. Legacy snapshots that
cannot be restored safely are rejected. Replacement is not a data-erasure tool.

## Reply tracking upgrade

Update Exiron to a server with `delivery_receipts: true` support (introduced in
commit `04198ba`), then run Xeba's migrations and start it with its locked SDK.
The reply tracking migration adds `exchanges.message_thread_id` and the
`outgoing_telegram_messages` table. It cannot recover IDs of older sent messages.

For confirmed sends, Xeba saves receipt IDs and the corresponding delivery
checkpoint in one database transaction. Text and sticker parts use separate,
stable idempotency keys when calling Exiron. Missing receipts do not cause a
confirmed send to be repeated, but that send cannot be matched to later replies.
Idempotency does not remove the ambiguous delivery cases described above.

If a reply without Xeba's name is ignored, check that:

- The target message was sent after both upgrades and the migration completed.
- Exiron delivered the incoming reply through the hook's listener.
- The incoming reply contains text or a media caption and was sent by a human.
- Its service, chat, and topic match the saved target, and the parent exchange
  and outgoing identity have not been deleted.

## Sticker identity upgrade

Run migrations before starting the new image. The sticker identity migration
merges byte-identical legacy bank entries within each chat, retaining their file-ID
aliases, emoji metadata, media, earliest creation time, and latest observation.
Conversation exchanges and their original sticker payloads are preserved.
Entries without media cannot be matched by content; later observations with a
`file_unique_id` can link their file-ID aliases to a stable identity.

Stable Telegram IDs take precedence over content matching. Distinct known IDs
remain separate, and legacy matches can be split when Telegram supplies more
specific identity information. Old payloads without `file_unique_id` remain
supported. A schema rollback does not recreate merged duplicate bank rows;
take a backup before upgrading as usual.
