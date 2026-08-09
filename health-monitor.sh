#!/usr/bin/env bash
# Downtime monitor: checks each local Coolify service/DB and raises a Sentry event on
# up->down and down->up transitions. Sources SENTRY_DSN from a running backend container,
# so no secret is stored here. Alerts only after FAIL_THRESHOLD consecutive failures, to
# tolerate brief deploy windows. Conf rows: "name kind target port path" (kind = http|pg).
#
# Installed on BOTH servers as /root/health-monitor.sh, run every two minutes by
# health-monitor.timer. /root/.health-env names the environment in the Sentry event.
set -uo pipefail

CONF=/root/health-monitor.conf
STATE_DIR=/root/.health-state
ENV_NAME="$(cat /root/.health-env 2>/dev/null || echo unknown)"
FAIL_THRESHOLD=2
mkdir -p "$STATE_DIR"

find_dsn() {
  local cid env
  for cid in $(docker ps -q); do
    env=$(docker inspect "$cid" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | grep '^SENTRY_DSN=' | head -1)
    if [ -n "$env" ]; then echo "${env#SENTRY_DSN=}"; return 0; fi
  done
}

send_sentry() { # dsn level message
  local dsn="$1" level="$2" msg="$3"
  [ -z "$dsn" ] && return 0
  local rest="${dsn#*://}"
  local key="${rest%%@*}"
  local hostproj="${rest#*@}"
  local host="${hostproj%%/*}"
  local proj="${hostproj##*/}"
  curl -s -m 10 -o /dev/null -X POST "https://${host}/api/${proj}/store/" \
    -H 'Content-Type: application/json' \
    -H "X-Sentry-Auth: Sentry sentry_version=7, sentry_client=health-monitor/1.0, sentry_key=${key}" \
    --data "{\"message\":\"${msg}\",\"level\":\"${level}\",\"platform\":\"other\",\"environment\":\"${ENV_NAME}\",\"server_name\":\"$(hostname)\",\"logger\":\"health-monitor\",\"tags\":{\"monitor\":\"downtime\"}}"
}

# During a rolling update two containers share the name prefix: the old one still serving
# traffic and the new one still booting. Picking blindly measured whichever Docker happened to
# list first, so a deploy could report a service DOWN that users never noticed — it did, for
# staging db-service on 2026-08-09. Prefer the container Docker considers healthy, which is the
# one actually taking traffic. Nothing is hidden by this: if no healthy container exists we fall
# back to the first match and the probe fails exactly as before, at the same speed.
container_for() { # name-prefix -> container id
  local cid
  cid=$(docker ps -q --filter "name=^$1" --filter "health=healthy" | head -1)
  [ -n "$cid" ] && { echo "$cid"; return 0; }
  docker ps -q --filter "name=^$1" | head -1
}

check() { # name kind target port path -> 0 up / 1 down
  local cid ip
  cid=$(container_for "$3"); [ -z "$cid" ] && return 1
  case "$2" in
    http)
      ip=$(docker inspect -f '{{.NetworkSettings.Networks.coolify.IPAddress}}' "$cid" 2>/dev/null); [ -z "$ip" ] && return 1
      curl -fsS -m 5 -o /dev/null "http://${ip}:${4}${5}" ;;
    pg)
      docker exec "$cid" pg_isready -q -t 3 >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

DSN=$(find_dsn)

while read -r name kind target port path; do
  [ -z "${name:-}" ] && continue
  case "$name" in \#*) continue;; esac
  if check "$name" "$kind" "$target" "$port" "$path"; then
    if [ -f "$STATE_DIR/$name.down" ]; then
      rm -f "$STATE_DIR/$name.down"
      send_sentry "$DSN" info "Service recovered: ${name} (${ENV_NAME})"
    fi
    echo 0 > "$STATE_DIR/$name.fails"
  else
    fails=$(( $(cat "$STATE_DIR/$name.fails" 2>/dev/null || echo 0) + 1 ))
    echo "$fails" > "$STATE_DIR/$name.fails"
    if [ "$fails" -ge "$FAIL_THRESHOLD" ] && [ ! -f "$STATE_DIR/$name.down" ]; then
      touch "$STATE_DIR/$name.down"
      send_sentry "$DSN" error "Service DOWN: ${name} (${ENV_NAME}) - health check failing"
    fi
  fi
done < "$CONF"
