# Production deployment

The supplied production shape is one Linux host:

```text
Internet
  -> nginx :443 (TLS)
  -> SuperX app :4000 on 127.0.0.1
  -> PostgreSQL on the private Compose network
```

The app container contains Phoenix, the Oban workers and scheduler, and the
optional Node XChat worker. PostgreSQL is the only other service. The Compose
file does not publish PostgreSQL to the host.

This guide assumes a Debian or Ubuntu server, a domain whose A/AAAA records
already point to it, Docker Engine with the Compose plugin, nginx, and certbot.
Package names differ on other distributions.

Read [Configuration](CONFIGURATION.md) before starting. In particular, back
up `SUPERX_VAULT_KEY`; a database backup without that key cannot recover the
stored X OAuth tokens or XChat identity keys.

## 1. Prepare the host

Create a deployment directory and clone the repository. Use the account that
will run deployments rather than `root` where practical.

```bash
sudo install -d -o "$USER" -g "$USER" /var/www/superx.free
git clone REPOSITORY_URL /var/www/superx.free
cd /var/www/superx.free
cp .env.example .env
chmod 600 .env
```

Replace `REPOSITORY_URL` with this project’s Git URL. If you use a different
directory, also set `DIR` when running `deploy.sh`.

Generate the two production secrets:

```bash
docker run --rm hexpm/elixir:1.19.5-erlang-26.2.5.20-debian-trixie-20260610-slim \
  sh -c 'mix local.hex --force >/dev/null && mix phx.gen.secret'
openssl rand -base64 32
```

Put the first result in `SECRET_KEY_BASE` and the second in
`SUPERX_VAULT_KEY`. Also generate a long hexadecimal PostgreSQL password so it
does not contain URI delimiters; Compose interpolates it directly into
`DATABASE_URL`:

```bash
openssl rand -hex 32
```

At minimum, review these `.env` entries:

```dotenv
POSTGRES_USER=superx
POSTGRES_PASSWORD=replace-with-a-random-password
POSTGRES_DB=superx
SECRET_KEY_BASE=replace-with-generated-secret
SUPERX_VAULT_KEY=replace-with-generated-key
PHX_HOST=superx.example.com
BIND_ADDR=127.0.0.1
X_CLIENT_ID=replace-with-x-client-id
X_CLIENT_SECRET=replace-with-x-client-secret
X_REDIRECT_URI=https://superx.example.com/auth/x/callback
```

Do not leave the example’s localhost `X_REDIRECT_URI` in a public deployment.
Register the same HTTPS callback, byte for byte, in the X developer console.
The X app must be an OAuth 2.0 Web App with PKCE. See
[Troubleshooting](TROUBLESHOOTING.md#x-sign-in-is-not-configured) if sign-in is
disabled.

Validate Compose expansion before it creates anything:

```bash
docker compose config >/dev/null
```

This catches blank required Compose values. It does not validate credentials
against external providers.

## 2. Build and start

Build the release and start PostgreSQL and the application:

```bash
docker compose up -d --build
docker compose ps
docker compose logs --tail=100 app
```

The app service waits for PostgreSQL’s health check. Its command is
`/app/bin/start`, which runs `/app/bin/migrate` and only then starts Phoenix.
Migrations therefore run on the first boot and are a no-op on later boots.
Do not wait for a healthy app container before trying to migrate it: Oban needs
its tables as soon as the application starts, which is precisely why migration
runs before application startup.

Confirm the release VM is alive:

```bash
docker compose exec app /app/bin/superx rpc 'IO.puts(:ok)'
```

The application is published only on `127.0.0.1:4000` by default. A direct
HTTP request normally redirects to the configured HTTPS host because
production forces SSL:

```bash
curl -I http://127.0.0.1:4000/
```

If you replace the image command or use a platform that does not run the
supplied startup script, migrate explicitly before starting the full app:

```bash
docker compose run --rm app /app/bin/migrate
```

## 3. Configure nginx, including LiveView

LiveView upgrades `/live/websocket` from HTTP to a WebSocket. Ordinary proxy
settings are not enough. If the upgrade headers are missing, the initial HTML
loads but pages show as disconnected and interactive actions do not work.

Create `/etc/nginx/sites-available/superx` with the following initial HTTP
virtual host. Replace `superx.example.com` in both places.

```nginx
server {
    listen 80;
    listen [::]:80;
    server_name superx.example.com;

    client_max_body_size 6m;

    location /live/websocket {
        proxy_pass http://127.0.0.1:4000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_buffering off;
    }

    location / {
        proxy_pass http://127.0.0.1:4000;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 60s;
        proxy_buffering off;
    }
}
```

The 6 MB nginx limit is slightly above the application’s 5 MB limit for each
image, GIF, or analytics CSV. SuperX itself accepts up to four images per post
segment and does not accept video in this upload flow.

Enable and test the site:

```bash
sudo ln -s /etc/nginx/sites-available/superx /etc/nginx/sites-enabled/superx
sudo nginx -t
sudo systemctl reload nginx
```

Remove the distribution’s default vhost if it claims the same hostname.

The forwarded protocol header is also required. `config/prod.exs` uses it to
distinguish an HTTPS request terminated at nginx from a real plain-HTTP
request. Without it, redirect loops are possible.

## 4. Issue and renew TLS certificates

With port 80 reachable from the Internet and DNS in place, let certbot add the
certificate and HTTPS listener:

```bash
sudo certbot --nginx -d superx.example.com
sudo nginx -t
sudo systemctl reload nginx
```

Choose the HTTP-to-HTTPS redirect when prompted. Inspect the resulting nginx
file and make sure the dedicated `/live/websocket` location and all of its
upgrade headers remain inside the HTTPS server block.

Test renewal:

```bash
sudo certbot renew --dry-run
systemctl status certbot.timer
```

Then test the public application:

```bash
curl -I https://superx.example.com/
```

Use the browser’s network panel to confirm that
`wss://superx.example.com/live/websocket` receives status `101 Switching
Protocols`. The browser may fall back to LiveView long polling, but a working
production proxy should support the WebSocket directly.

## 5. Start the Compose project at boot

The Compose services already use `restart: unless-stopped`. Docker starts
them again after a daemon or host restart. A small systemd unit makes the
project’s desired state explicit and provides one place for operators to
start and stop it.

First find the Docker binary:

```bash
command -v docker
```

Create `/etc/systemd/system/superx.service`. If the command above is not
`/usr/bin/docker`, change both command paths below.

```ini
[Unit]
Description=SuperX Docker Compose application
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/var/www/superx.free
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose stop
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
```

Enable it:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now superx.service
sudo systemctl status superx.service
```

This unit does not build images at boot. Perform the first
`docker compose up -d --build` before enabling it, and use `deploy.sh` or a
manual build for upgrades. Docker container logs remain available through
`docker compose logs`; the oneshot unit has little application output of its
own.

## Day-to-day operation

Useful read-only checks:

```bash
cd /var/www/superx.free
docker compose ps
docker compose logs --tail=100 app
docker compose logs --tail=100 db
docker compose exec app /app/bin/superx rpc 'IO.puts(:ok)'
```

Follow app logs during an incident:

```bash
docker compose logs -f app
```

Restart only the application:

```bash
docker compose restart app
```

Recreate it after an `.env` change:

```bash
docker compose up -d --force-recreate app
```

`docker compose down` removes containers and the Compose network but keeps the
named volumes. `docker compose down -v` deletes both PostgreSQL and uploaded
media. Do not use `-v` on a production instance unless data deletion is the
explicit goal and a restore has been tested.

## What `deploy.sh` does

`deploy.sh` deploys through SSH without requiring the production server to
reach the Git forge:

1. It refuses to run if the local worktree has tracked or untracked changes.
   Only commits can be deployed.
2. It creates a temporary Git bundle containing all local refs.
3. It copies that bundle to `$HOST:/tmp/superx.bundle` with SCP.
4. On the server, it changes to `$DIR`, fetches the bundle’s local `main`
   branch into `refs/remotes/bundle/main`, and hard-resets the checked-out
   worktree to it.
5. It rebuilds the `app` image and force-recreates only the app service. The
   PostgreSQL container and named volumes remain in place.
6. The new app container runs migrations before Phoenix and Oban start.
7. It removes the remote bundle and polls `https://superx.free/` every three
   seconds for up to 90 seconds, looking for HTTP 200.

Important limits follow directly from the script:

- The deployed revision is local `main`, not necessarily local `HEAD`. Run it
  with the intended commit on `main`.
- The remote checkout is reset with `git reset --hard`. Never keep uncommitted
  server-side edits in that checkout. `.env` is ignored by Git and remains.
- `HOST` defaults to the SSH alias `kit`; `DIR` defaults to
  `/var/www/superx.free`.
- `HOST=other` changes the SSH destination but not the health-check URL. For a
  differently named site, verify it manually or update the script in your
  fork.
- It does not provision Docker, nginx, TLS, `.env`, volumes, or systemd. Do
  the first-host setup in this guide before using it.
- It has no automatic rollback. The previous image may remain in Docker’s
  local image store, but the script does not tag or restore it.

Run it from a clean local checkout:

```bash
./deploy.sh
HOST=my-production-host DIR=/var/www/superx.free ./deploy.sh
```

If its final health check fails, use the command it prints, then inspect the
full logs rather than only the last 40 lines:

```bash
ssh my-production-host 'cd /var/www/superx.free && docker compose logs --tail=200 app'
```

## Backups

A complete recoverable backup has three parts:

1. PostgreSQL, including users, posts, jobs, the corpus, vectors, and the paid
   read cache.
2. The `uploads` volume, because queued posts store opaque file keys in the
   database and need the corresponding local files at publish time.
3. `.env`, especially `SUPERX_VAULT_KEY`. Store this copy encrypted and away
   from the server.

The following commands create a consistent application-level pair by stopping
the app while PostgreSQL stays online. Choose a backup directory outside the
Git checkout.

```bash
cd /var/www/superx.free
sudo install -d -m 700 -o "$USER" -g "$USER" /var/backups/superx
backup_stamp="$(date -u +%Y%m%dT%H%M%SZ)"

docker compose stop app
docker compose exec -T db sh -c \
  'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" --format=custom' \
  > "/var/backups/superx/postgres-${backup_stamp}.dump"
docker compose run --rm --no-deps -T app sh -c \
  'tar -C /app -czf - uploads' \
  > "/var/backups/superx/uploads-${backup_stamp}.tar.gz"
docker compose start app
```

Copy `.env` separately into encrypted off-host storage. A plain local copy can
be staged with restrictive permissions, but it is still a secrets file:

```bash
install -m 600 .env "/var/backups/superx/env-${backup_stamp}"
```

Move the three files off the host, encrypt them at rest, apply a retention
policy, and test restores. A backup that exists only on the application disk
does not cover disk or host loss.

The read cache and corpus can make the database much larger over time. Cache
rows deliberately do not expire from storage, and corpus posts are upserted
rather than periodically purged. Monitor volume capacity.

## Restore drill

The following database restore replaces the current database. Stop and verify
the target before running it. Use matching files from the same backup window.

```bash
cd /var/www/superx.free
docker compose stop app

docker compose exec -T db sh -c \
  'dropdb --if-exists -U "$POSTGRES_USER" "$POSTGRES_DB" && createdb -U "$POSTGRES_USER" "$POSTGRES_DB"'

docker compose exec -T db sh -c \
  'pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" --no-owner --no-privileges' \
  < /path/to/postgres-backup.dump

docker compose run --rm --no-deps -T app sh -c \
  'rm -rf /app/uploads/* && tar -C /app -xzf -' \
  < /path/to/uploads-backup.tar.gz

docker compose up -d app
docker compose logs --tail=100 app
```

Restore the matching `.env` before starting the app. In particular, use the
same `SUPERX_VAULT_KEY` that encrypted the database’s OAuth tokens and XChat
identity keys. Without it, accounts must reconnect and encrypted chat history
may become unreadable. The startup script applies any migrations newer than
the restored dump.

The media restore intentionally clears the target upload directory. Run it
only during an explicit restore. If the backup itself contains an `uploads/`
directory, extracting it under `/app` recreates the expected path.

## Related reference

- [Setup](SETUP.md)
- [Configuration](CONFIGURATION.md)
- [Architecture](ARCHITECTURE.md)
- [Troubleshooting](TROUBLESHOOTING.md)
- [FAQ](FAQ.md)
