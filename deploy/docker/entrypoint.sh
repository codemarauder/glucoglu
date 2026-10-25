#!/bin/sh
# Container PID 1 (under docker's init): run all runit services, stop them cleanly.
#
# runsvdir alone exits at once on SIGTERM and leaves its services running, so
# `docker stop` would kill them hard. Here a TERM or INT first stops every service
# (sv force-stop: TERM, then KILL after the wait), then ends runsvdir.
SVDIR=${SVDIR:-/etc/service}

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
