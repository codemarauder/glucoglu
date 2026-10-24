# Glucoglu

Self-hosted glucose monitoring and analytics. Perl / Mojolicious + PostgreSQL + PWA, no npm, no pip.

> Glucoglu: the glue for your glucose data from Juggluco.

Design and scope: `libreglue-scope-design.md` (handoff v2.1). License: AGPLv3.

## What step 1 contains

- Mojolicious skeleton
- Login: email link + code (no passwords, D9). Invite code on first login only.
- SMTP for the mail (any relay). Credentials from environment.
- PostgreSQL: users, invites, tokens, mail_log (auto-migrated at startup).

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
    script/glucoglu-admin prune             # drop expired login tokens and old mail log

Cron the `prune` (e.g. daily). 

## Juggluco ingestion

Get your ingest token from the dashboard, then point Juggluco's upload at:

    POST /api/v1/entries?token=YOUR_TOKEN

Nightscout-style JSON (`{"type":"sgv","date":<epoch ms>,"sgv":<value>}`, single object or array). Values are auto-detected as mg/dL or mmol/L and stored as mg/dL; duplicate readings are ignored. Unreadable payloads are kept in `payload_log` for diagnosis.

## Deploy (Debian 12)

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

    # 3. Environment file /etc/glucoglu.env (root-readable only). systemd loads it
    #    (EnvironmentFile= in deploy/glucoglu.service). Never commit real values.
    GLUCOGLU_SECRET=<random>
    GLUCOGLU_DB_DSN=postgresql://glucoglu:PASS@localhost/glucoglu
    GLUCOGLU_URL=https://app.example.org
    GLUCOGLU_SMTP_HOST=<your relay host>  GLUCOGLU_SMTP_PORT=587
    GLUCOGLU_SMTP_USER=<credential>  GLUCOGLU_SMTP_PASS=<credential>
    GLUCOGLU_SMTP_FROM=glucoglu@app.example.org

    # 4. systemd (adjust the perlbrew path in the unit to the installed perl version)
    cp deploy/glucoglu.service /etc/systemd/system/
    systemctl daemon-reload && systemctl enable --now glucoglu

    # 5. Apache: TLS + reverse proxy (get a cert for your domain, e.g. certbot --apache)
    a2enmod proxy proxy_http headers
    cp deploy/glucoglu.apache.conf /etc/apache2/sites-available/
    a2ensite glucoglu
    systemctl reload apache2

## DNS and mail checklist

- A/AAAA records for your domain pointing at the server.
- At your SMTP relay: add the sending domain, set the SPF and DKIM DNS records it shows, create SMTP credentials.
- Send yourself one test mail before the first login; if it lands in spam, the DKIM record is wrong.