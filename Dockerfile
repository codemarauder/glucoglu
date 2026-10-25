# Glucoglu container
# License: AGPL-3.0
#
# One image, two roles (deploy/docker/entrypoint.sh; docker-compose.yml runs both):
#   app       runit services: glucoglu (web app, Mojolicious prefork on :3000; Apache on
#             the host owns TLS), glucoglu-prune (daily), import-<name> (Libre 1 sync for
#             each Juggluco user, every 60 s)
#   juggluco  runit services: juggluco-<name> (Juggluco mirror receiver for each user)
#
# PostgreSQL runs on the host. See README, section Deploy.
#
# Build and run: docker compose up -d --build

FROM debian:trixie-slim

LABEL description="Glucoglu: the glue for your glucose data from Juggluco"
LABEL license="AGPL-3.0"

ENV DEBIAN_FRONTEND=noninteractive

# Owner of the Juggluco data folder on the host: the export writes there.
ARG APP_UID=1000

WORKDIR /app
COPY cpanfile /app/

# Perl modules:
# - DBD::Pg and IO::Socket::SSL wrap C libraries (libpq, OpenSSL). They come from Debian,
#   so they get security updates with the base image, and the image needs no compiler.
# - Mojolicious and Mojo::Pg are pure Perl and come from CPAN: Debian trixie has
#   Mojolicious 9.39, and 9.48 fixes CVE-2026-15747 (cpanfile requires >= 9.48).
# cpanminus and make are only needed for the install and are removed in the same layer.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      perl libdbd-pg-perl libio-socket-ssl-perl ca-certificates runit curl \
      cpanminus make \
 && cpanm --notest --installdeps /app \
 && apt-get purge -y cpanminus make \
 && apt-get autoremove -y --purge \
 && rm -rf /var/lib/apt/lists/* /root/.cpanm

RUN useradd --system --uid "$APP_UID" --home-dir /app --shell /usr/sbin/nologin glucoglu

# Application code: owned by root, read-only for the app user.
COPY glucoglu.conf glucoglu.production.conf /app/
COPY lib/       /app/lib/
COPY script/    /app/script/
COPY templates/ /app/templates/
COPY public/    /app/public/

# Static runit services and the entrypoint. The entrypoint links the services for its
# role into /etc/service at start, and makes one service per Juggluco user.
COPY deploy/docker/sv/           /etc/sv/
COPY deploy/docker/entrypoint.sh /usr/local/bin/glucoglu-entrypoint
RUN chmod 755 /app/script/* /etc/sv/*/run /usr/local/bin/glucoglu-entrypoint

EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD curl -sf http://127.0.0.1:3000/health || exit 1

ENTRYPOINT ["/usr/local/bin/glucoglu-entrypoint"]
CMD ["app"]
