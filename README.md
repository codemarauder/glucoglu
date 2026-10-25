# Glucoglu

Self-hosted glucose monitoring and analytics. Perl / Mojolicious + PostgreSQL + PWA, no npm, no pip.

> Glucoglu: the glue for your glucose data from Juggluco.

Design and scope: `glucoglu-scope-design.md`. License: AGPLv3.

## What v1 contains so far

- Mojolicious skeleton
- Login: email link + code (no passwords, D9). Invite code on first login only.
- PostgreSQL: full v1 schema — users, invites, login tokens, mail_log, readings, meals, insulin, IOB, exercise, notes, lab A1c, shares (auto-migrated at startup).
- Ingest: Juggluco uploader (Libre 2+ stream, Nightscout V1/V3 auth) and mirror TSV import (Libre 1 scans/history).
- Dashboard: Tier 1 metrics — TIR/TAR/TBR, mean, SD, CV, GMI, eA1c, data sufficiency, hypo/hyper events — plus AGP percentiles by time of day; windows 7/14/30/90 days; read-only caregiver access via the shares table (D10).

## Development

    apt install postgresql libpq-dev build-essential cpanminus
    cpanm --installdeps .
    sudo -u postgres createuser glucoglu --pwprompt
    sudo -u postgres createdb -O glucoglu glucoglu
    sudo -u postgres psql glucoglu -c "INSERT INTO invites (code) VALUES ('DEV-INVITE')"
    GLUCOGLU_DB_DSN=postgresql://glucoglu:PASS@localhost/glucoglu morbo script/glucoglu

## Tests

Tests need a throwaway database (they create and wipe rows):

    sudo -u postgres createdb -O glucoglu glucoglu_test
    GLUCOGLU_DB_DSN=postgresql://glucoglu:PASS@localhost/glucoglu_test prove -l t

## Maintenance

Run on the server with the app's environment (`GLUCOGLU_DB_DSN`). No web admin in v1; the operator is the admin.

    script/glucoglu-admin invite            # mint an invite code
    script/glucoglu-admin users             # list users
    script/glucoglu-admin delete EMAIL      # delete a user and their tokens/mail log
    script/glucoglu-admin login EMAIL     # login link without mail (dev / mailbox recovery)
    script/glucoglu-admin prune           # drop expired login tokens and old mail log

The runit service `glucoglu-prune` runs `prune` daily (both deploy options). In the Docker container, run the commands as:

    docker exec -u glucoglu glucoglu perl script/glucoglu-admin users

## Juggluco ingestion

Get your ingest token from the dashboard, then point Juggluco's upload at:

    POST /api/v1/entries?token=YOUR_TOKEN

Nightscout-style JSON (`{"type":"sgv","date":<epoch ms>,"sgv":<value>}`, single object or array). Values are auto-detected as mg/dL or mmol/L and stored as mg/dL; duplicate readings are ignored. Unreadable payloads are kept in `payload_log` for diagnosis. Auth: token as query parameter, `Authorization: Bearer` (V3), or `api-secret: <sha1 of token>` header (V1, Juggluco's default).

**Note:** Juggluco's uploader only pushes Bluetooth stream values (Libre 2/2+/3). Libre 1 sensors are NFC-only — their scans and history never reach the uploader. For Libre 1, use the mirror pipeline:

    # 1. Juggluco server (cmdline) on any host, configured as mirror receiver
    ./juggluco -riP -L <label> -w <password> -G && ./juggluco    # daemon
    # 2. Phone: Mirror -> Add connection -> your host, port 8795, Scans (+Amounts)
    # 3. Sync loop: the runit service glucoglu-import (see Deploy) runs script/libre1-sync
    #    every 60 s. It exports both TSVs from the same data dir and imports them.
    #    By hand:
    ./juggluco -H history.tsv && ./juggluco -S scans.tsv
    script/glucoglu-admin import history history.tsv EMAIL
    script/glucoglu-admin import spot scans.tsv EMAIL

EMAIL must be an existing user (log in once first); the import refuses an unknown address. Re-running the import is safe — duplicate readings are ignored, and rows older than the newest stored row minus 9 h are skipped. History is the main data (~96 points/day at 15-min intervals); spot values are a bonus.

## Deploy

Two options, with the same runit service names. In both, PostgreSQL and Apache (TLS on 443) run on the host, and Apache proxies to `127.0.0.1:3000`.

- **Option A: Docker.** One container with runit inside. No Perl on the host.
- **Option B: on the host with runit.** Perl in perlbrew.

| runit service | Does |
|---|---|
| `glucoglu` | web app on :3000 |
| `glucoglu-import` | Libre 1 sync (`script/libre1-sync`) every 60 s |
| `glucoglu-prune` | daily prune of expired tokens and old mail log |
| `juggluco-receiver` | Docker only, optional: Juggluco mirror receiver (`JUGGLUCO_RECEIVER=1`) |

### Option A: Docker (runit inside the container)

`Dockerfile`, `docker-compose.yml`, `deploy/docker/`. The container reaches PostgreSQL through the Docker bridge gateway `172.31.250.1` (pinned in `docker-compose.yml`).

    # 1. PostgreSQL on the host
    apt install postgresql
    sudo -u postgres createuser glucoglu --pwprompt
    sudo -u postgres createdb -O glucoglu glucoglu
    # Let PostgreSQL bind the bridge address even before Docker creates the bridge (boot order):
    echo 'net.ipv4.ip_nonlocal_bind = 1' > /etc/sysctl.d/90-glucoglu.conf && sysctl --system
    # postgresql.conf:  listen_addresses = 'localhost,172.31.250.1'
    # pg_hba.conf:      host  glucoglu  glucoglu  172.31.250.0/24  scram-sha-256
    service postgresql restart
    ufw allow in on br-glucoglu to 172.31.250.1 port 5432 proto tcp

    # 2. Settings: all in .env next to docker-compose.yml (git-ignored, docker-ignored).
    #    Never commit real values. The user who runs docker compose must read it.
    cp deploy/docker/env.example .env
    chmod 600 .env                            # then fill it in

    # 3. Juggluco folder (static binary + jugglucodata/): set JUGGLUCO_HOST_DIR in .env,
    #    and GLUCOGLU_UID to the uid that owns it:
    ls -ln /opt/juggluco

    # 4. Build and start; the app runs its database migrations at start
    docker compose up -d --build
    curl -s http://127.0.0.1:3000/health          # ok
    docker exec -u glucoglu glucoglu perl script/glucoglu-admin invite

    # 5. Apache: as in option B, step 5

#### Operation (Docker)

    docker compose logs -f                                   # all services
    docker exec glucoglu sv status /etc/service/*            # all must show "run"
    docker exec glucoglu sv restart /etc/service/glucoglu-import
    docker compose up -d --build                             # after git pull

`docker stop` stops each service cleanly (`deploy/docker/entrypoint.sh`): `runsvdir` alone exits on SIGTERM and leaves its services to be killed.

### Option B: on the host with runit (perlbrew)

The app Perl lives in perlbrew (no distro-Perl pollution). A front-end proxy (e.g. Apache) owns TLS on 443 and proxies to hypnotoad on `127.0.0.1:3000`.

    # 1. User, code, perlbrew Perl
    apt install build-essential curl libpq-dev     # build deps only; perlbrew does the rest
    adduser --system --group --home /opt/glucoglu --shell /bin/bash glucoglu
    su - glucoglu
    curl -L https://install.perlbrew.pl | bash && exec bash
    perlbrew install perl-5.40.0
    perlbrew lib create perl-5.40.0@glucoglu
    perlbrew use perl-5.40.0@glucoglu
    git clone <repo> /opt/glucoglu && cd /opt/glucoglu
    cpanm --installdeps .

    # 2. Postgres (distro package for the database service is fine)
    apt install postgresql
    sudo -u postgres createuser glucoglu --pwprompt
    sudo -u postgres createdb -O glucoglu glucoglu
    sudo -u postgres psql glucoglu -c "INSERT INTO invites (code) VALUES ('CHANGE-ME')"

    # 3. Environment: an envdir, one file per variable (first line = value), read by
    #    runit's chpst as root. An empty file means the variable is not set.
    #    Never commit real values.
    mkdir -p /etc/glucoglu
    cp -r deploy/runit/env.example /etc/glucoglu/env
    chown -R root: /etc/glucoglu && chmod 700 /etc/glucoglu/env
    #    Fill in: GLUCOGLU_SECRET (random), GLUCOGLU_DB_DSN, GLUCOGLU_URL,
    #    GLUCOGLU_SMTP_HOST / _PORT / _USER / _PASS / _FROM, GLUCOGLU_LIBRE1_EMAIL
    #    (Libre 1 only), PERL5LIB (the lib folder of perl-5.40.0@glucoglu, usually
    #    /opt/glucoglu/.perlbrew/libs/perl-5.40.0@glucoglu/lib/perl5; see `perlbrew lib list`).
    #    MOJO_MODE=production is already set. Keep it: without it Mojolicious runs in
    #    development mode, the GLUCOGLU_SECRET check does not run and the session
    #    cookie is not marked secure.
    #    Optional: JUGGLUCO_DIR (default /opt/juggluco) for the Libre 1 sync.

    # 4. runit (apt install runit). Web app: hypnotoad in the foreground.
    #    Libre 1 sync loop: omit glucoglu-import if you have no Libre 1.
    #    glucoglu-prune: daily prune of expired tokens and old mail log.
    cp -r deploy/runit/glucoglu deploy/runit/glucoglu-import deploy/runit/glucoglu-prune /etc/sv/
    chmod +x /etc/sv/glucoglu*/run /etc/sv/glucoglu*/log/run
    mkdir -p /var/log/glucoglu /var/log/glucoglu-import /var/log/glucoglu-prune
    chown glucoglu: /var/log/glucoglu /var/log/glucoglu-import /var/log/glucoglu-prune
    ln -s /etc/sv/glucoglu /etc/sv/glucoglu-import /etc/sv/glucoglu-prune /etc/service/
    #    The perl path (perl-5.40.0) is in the three deploy/runit/*/run files:
    #    change it there if you install another version.

    # 5. Apache: TLS + reverse proxy (get a cert for your domain, e.g. certbot --apache)
    a2enmod proxy proxy_http headers
    cp deploy/glucoglu.apache.conf /etc/apache2/sites-available/
    a2ensite glucoglu
    systemctl reload apache2

#### Operation (host)

    sv status glucoglu glucoglu-import glucoglu-prune   # all must show "run"
    sv restart glucoglu                     # after a code or env change
    sv down glucoglu-import                 # stop the sync loop (sv up to start)
    tail /var/log/glucoglu/current          # web app log
    tail /var/log/glucoglu-import/current   # one line per import run

The import log shows one line for each import (inserted, duplicates, rejected, skipped). If the Juggluco export fails, the log shows the export output and the loop tries again after 60 s.

## DNS and mail checklist

- A/AAAA records for your domain pointing at the server.
- At your SMTP relay: add the sending domain, set the SPF and DKIM DNS records it shows, create SMTP credentials.
- Send yourself one test mail before the first login; if it lands in spam, the DKIM record is wrong.