#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 Nishant Sharma <nishant@hopbox.in>
# Container PID 1 (under docker's init). Makes the runit services, runs them, and
# stops them cleanly on `docker stop`.
#
# Role (first argument):
#   app       web app, daily prune, and one Libre 1 import per Juggluco user (default)
#   juggluco  one Juggluco mirror receiver per Juggluco user (no secrets in this container)
#
# Juggluco users: $JUGGLUCO_ROOT/users/<name>/ is the Juggluco data folder of one person
# (used with -d). It holds user.conf with one line EMAIL=<their Glucoglu account>.
# The binary is $JUGGLUCO_ROOT/juggluco. A restart reads the users again.
#
# runsvdir alone exits at once on SIGTERM and leaves its services running, so
# `docker stop` would kill them hard. Here a TERM or INT first stops every service
# (sv force-stop: TERM, then KILL after the wait), then ends runsvdir.
set -u
ROLE=${1:-app}
SVDIR=${SVDIR:-/etc/service}
JUGGLUCO_ROOT=${JUGGLUCO_ROOT:-/juggluco}
BIN=$JUGGLUCO_ROOT/juggluco

# One service: $1 = name, $2 = run script body.
mksv() {
  mkdir -p "$SVDIR/$1"
  printf '#!/bin/sh\nexec 2>&1\n%s\n' "$2" > "$SVDIR/$1/run"
  chmod 755 "$SVDIR/$1/run"
}

rm -rf "$SVDIR" && mkdir -p "$SVDIR"
case $ROLE in
  app)      ln -s /etc/sv/glucoglu /etc/sv/glucoglu-prune "$SVDIR"/ ;;
  juggluco) ;;
  *)        echo "entrypoint: unknown role '$ROLE' (app or juggluco)"; exit 64 ;;
esac

users=0
for dir in "$JUGGLUCO_ROOT"/users/*/; do
  [ -d "$dir" ] || continue
  dir=${dir%/}
  name=${dir##*/}
  case $name in
    *[!a-z0-9_-]*) echo "entrypoint: skip $dir: the name may only use a-z 0-9 _ -"; continue ;;
  esac
  if [ ! -x "$BIN" ]; then
    echo "entrypoint: no Juggluco binary at $BIN: no Juggluco services"; break
  fi
  if [ "$ROLE" = app ]; then
    email=$(sed -n 's/^EMAIL=//p' "$dir/user.conf" 2>/dev/null | head -n 1)
    case $email in
      *@*.*) case $email in *[!A-Za-z0-9._%+@-]*) email= ;; esac ;;
      *)     email= ;;
    esac
    if [ -z "$email" ]; then
      echo "entrypoint: skip $name: no valid EMAIL= line in $dir/user.conf"; continue
    fi
    # One export + import, then wait 60 s. runit starts it again, so runs never overlap.
    mksv "import-$name" "chpst -u glucoglu env GLUCOGLU_LIBRE1_EMAIL='$email' JUGGLUCO_BIN='$BIN' JUGGLUCO_DATA='$dir' /app/script/libre1-sync
exec sleep ${JUGGLUCO_IMPORT_INTERVAL:-60}"
  else
    # The receiver listens on the port set in its own configuration (-d <dir> -p <port>).
    # It writes debug lines for each packet: they go to the log only with JUGGLUCO_DEBUG=1.
    # The start line shows each (re)start in the log.
    if [ "${JUGGLUCO_DEBUG:-0}" = 1 ]; then quiet=; else quiet=' >/dev/null 2>&1'; fi
    mksv "juggluco-$name" "cd '$dir' || exit 1
echo 'juggluco-$name: receiver start'
exec chpst -u glucoglu '$BIN' -d '$dir'$quiet"
  fi
  users=$((users + 1))
done
echo "entrypoint: role $ROLE, $users Juggluco user(s)"

runsvdir -P "$SVDIR" &
runsvdir_pid=$!

stop() {
  sv -w 20 force-stop "$SVDIR"/* >/dev/null 2>&1
  sv exit "$SVDIR"/* >/dev/null 2>&1
  kill -HUP "$runsvdir_pid" 2>/dev/null
  wait "$runsvdir_pid"
  exit 0
}
trap stop TERM INT

wait "$runsvdir_pid"
