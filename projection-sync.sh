#!/usr/bin/env bash
# Keeps the projection store's idea of *who exists* and *what they have played* current.
#
# Both are ingestion the service has no scheduler of its own for, and both had been run by hand
# — which is how the rookie markers went wrong in the first place. The ESPN player pool syncs
# itself nightly, so the app learns about a prospect within a day of him signing; until this
# ran, the projection store did not, and he read on screen as a veteran because nothing had
# ever told the store he existed.
#
#   projection rosters                  who exists — rosters + prospect lists, identity only
#   projection ingest --season <year>    what they played — MoneyPuck + NHL boxcar
#
# Installed on the STAGING server only, as /root/projection-sync.sh, run daily by
# projection-sync.timer. Production deliberately has no projection-service (see
# INFRASTRUCTURE.md §8), so there is nothing here for it to talk to.
#
# Failures are reported to Sentry through the same DSN file health-monitor.sh uses. A sync that
# fails quietly is the whole problem this guards against: nothing breaks, no page errors, the
# rookie markers just gently stop being true.
set -uo pipefail

# Coolify application UUID for staging's fantasy-projection-service, matched as a container-name
# prefix so it survives redeploys. Same value as the projection-service row in
# health-monitor.staging.conf; keep the two in step.
APP_UUID=ipxsgd6mzpekvwsny4zabc73

DSN_FILE=/root/.health-dsn
ENV_NAME="$(cat /root/.health-env 2>/dev/null || echo unknown)"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }

# During a rolling update two containers share the prefix: the old one still serving and the new
# one still booting. Prefer the one Docker calls healthy, exactly as health-monitor.sh does —
# running a sync inside a container that is about to be discarded would throw the work away.
container_for() { # name-prefix -> container id
  local cid
  cid=$(docker ps -q --filter "name=^$1" --filter "health=healthy" | head -1)
  [ -n "$cid" ] && { echo "$cid"; return 0; }
  docker ps -q --filter "name=^$1" | head -1
}

send_sentry() { # level message
  local dsn level msg rest key hostproj host proj
  level="$1"; msg="$2"
  [ -s "$DSN_FILE" ] || return 0
  dsn="$(tr -d '[:space:]' < "$DSN_FILE")"
  [ -z "$dsn" ] && return 0
  rest="${dsn#*://}"; key="${rest%%@*}"; hostproj="${rest#*@}"
  host="${hostproj%%/*}"; proj="${hostproj##*/}"
  curl -s -m 10 -o /dev/null -X POST "https://${host}/api/${proj}/store/" \
    -H 'Content-Type: application/json' \
    -H "X-Sentry-Auth: Sentry sentry_version=7, sentry_client=projection-sync/1.0, sentry_key=${key}" \
    --data "{\"message\":\"${msg}\",\"level\":\"${level}\",\"platform\":\"other\",\"environment\":\"${ENV_NAME}\",\"server_name\":\"$(hostname)\",\"logger\":\"projection-sync\",\"tags\":{\"monitor\":\"ingestion\"}}"
}

# The season with games in it, as a start year. The NHL season opens in October, so from October
# that is this calendar year and before it the one before. Asking MoneyPuck for a season that has
# not been played yet returns nothing useful and would only ever fail, so the cutover is the
# opening month rather than the summer.
current_season() {
  local year month
  year=$(date -u +%Y); month=$(date -u +%m)
  if [ "$((10#$month))" -ge 10 ]; then echo "$year"; else echo "$((year - 1))"; fi
}

CID="$(container_for "$APP_UUID")"
if [ -z "$CID" ]; then
  log "no projection-service container matching ${APP_UUID}; nothing to do"
  send_sentry error "projection-sync: no projection-service container found"
  exit 1
fi

SEASON="$(current_season)"
failed=0

# Rosters first. It is the cheap half and the half that fixes a wrong rookie marker, so it should
# not be held hostage to the ingest that follows it failing.
log "projection rosters"
if output=$(docker exec "$CID" projection rosters 2>&1); then
  log "  $output"
else
  log "  FAILED: $output"
  send_sentry error "projection-sync: projection rosters failed"
  failed=1
fi

log "projection ingest --season ${SEASON}"
if output=$(docker exec "$CID" projection ingest --season "$SEASON" 2>&1); then
  log "  $output"
else
  log "  FAILED: $output"
  send_sentry error "projection-sync: projection ingest --season ${SEASON} failed"
  failed=1
fi

exit "$failed"
