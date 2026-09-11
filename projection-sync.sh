#!/usr/bin/env bash
# Keeps the projection store's idea of *who exists* and *what they have played* current.
#
# Both are ingestion the service has no scheduler of its own for, and both had been run by hand
# — which is how the rookie markers went wrong in the first place. The ESPN player pool syncs
# itself nightly, so the app learns about a prospect within a day of him signing; until this
# ran, the projection store did not, and he read on screen as a veteran because nothing had
# ever told the store he existed.
#
#   projection rosters                   who exists — rosters + prospect lists, identity only
#   projection ingest --season <year>    what they played — MoneyPuck + NHL boxcar
#   projection game-logs --season <year> what they played, game by game — in season only
#   projection schedule --season <year>  when the season's games fall — in season only
#   projection injuries                  who is hurt right now — ESPN's report
#   projection lines                     what role they are expected to play — Daily Faceoff
#   projection project --season <year>   what we think they will do — the model's own output
#
# The injuries step is the one that has to run *often* rather than once. It is a snapshot with no
# archive, the return dates are a club's guess and they slip, and the projection is only as fresh
# as the last refresh: a player listed back on 7 November has to stop being deducted once he is
# back. It runs before the projection because the projection reads it.
#
# The game logs and the schedule run only in season, from the morning after opening night to the
# end of June, when the season with games in it is the season being projected. Until they ran, the
# store's newest calendar in season was last season's game logs moved forward a year: a 2026-27
# return date was counted against
# 2025-26's three-week Olympic break, and Who's hot had no games at all for the season underway.
# A return date is counted on the schedule and not on the logs, because the logs stop at last
# night. Out of season neither runs, so the summer is the run it was before they existed.
#
# The lines step is a snapshot too, and for the same reason has to be taken repeatedly: there is
# no archive of what a club's page said last week, so a day not swept is a day gone. The model reads
# these rows: a skater's line floors his games, his line and his power-play and penalty-kill units
# move his ice time and scoring, and a goalie's place on the depth chart moves his starts
# (projection-service #144 and #154 to #160). It reads 32 pages of somebody else's site at one a
# second, so it is the slowest step here by wall clock and by far the cheapest by work done.
#
# The last one is what makes the others visible. The API serves stored projection rows, so
# data that lands without a re-projection changes nothing a user can see: the store moves and
# the numbers on screen stay where the last hand-run left them. It goes last because it reads
# what every step before it writes.
#
# Installed as /root/projection-sync.sh on every server that runs projection-service, and run
# daily there by projection-sync.timer. It is the same file on staging and in production, with
# no per-host edit: it finds its container itself (below). Where it is installed, and how to
# install it, is projection-sync-setup.md.
#
# Failures are reported to Sentry through the same DSN file health-monitor.sh uses. A sync that
# fails quietly is the whole problem this guards against: nothing breaks, no page errors, the
# rookie markers just gently stop being true.
#
#   projection-sync.sh                    run the sync
#   projection-sync.sh --find-container   print the service and container it would use, run nothing
set -uo pipefail

# Coolify stamps every application container with the app's name as `coolify.serviceName`:
# `staging-projection-service` on staging, `prod-projection-service` in production. Matching the
# suffix is what lets one file serve both. This used to be staging's application UUID, written
# into the script with a note to keep it in step with health-monitor.staging.conf by hand, which
# made the file wrong on every other host by construction.
SERVICE_SUFFIX=-projection-service

DSN_FILE=/root/.health-dsn
ENV_NAME="$(cat /root/.health-env 2>/dev/null || echo unknown)"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }

# The distinct Coolify service names on this host that end in the suffix, one per line. More than
# one is refused rather than guessed between: a second app named like this one (a copy, a preview
# environment) is somebody's deliberate change, and syncing the wrong store would look like a
# success.
projection_services() {
  docker ps --format '{{.Label "coolify.serviceName"}}' | grep -e "${SERVICE_SUFFIX}\$" | sort -u
}

# During a rolling update two containers carry the same service name: the old one still serving
# and the new one still booting. Prefer the one Docker calls healthy, exactly as health-monitor.sh
# does — running a sync inside a container that is about to be discarded would throw the work away.
container_for() { # coolify service name -> container id
  local cid
  cid=$(docker ps -q --filter "label=coolify.serviceName=$1" --filter "health=healthy" | head -1)
  [ -n "$cid" ] && { echo "$cid"; return 0; }
  docker ps -q --filter "label=coolify.serviceName=$1" | head -1
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

# The season with games in it, as a start year: the newest season whose opening night has passed,
# by the NHL's own published dates (`projection season-underway`). It used to be a calendar rule,
# October on, and seasons do not open by the calendar: 2026-27 opens on 29 September, so its first
# two nights were read as the season before. Asking MoneyPuck for a season with no games in it
# returns nothing useful, which is why the cutover is opening night and not the summer.
#
# If the service cannot say (the NHL is down, or the container predates the command), the October
# rule stands in, with a warning to the journal and to Sentry: a sync that ran on a guessed season
# must not look like one that knew.
current_season() {
  local answer year month
  answer=$(docker exec "$CID" projection season-underway 2>/dev/null \
    | sed -n 's/^Season underway: \([0-9][0-9][0-9][0-9]\),.*/\1/p')
  if [ -n "$answer" ]; then echo "$answer"; return 0; fi
  log "WARNING: projection season-underway gave no answer; taking October as opening night" >&2
  send_sentry warning "projection-sync: could not read which season is underway; used the October rule"
  year=$(date -u +%Y); month=$(date -u +%m)
  if [ "$((10#$month))" -ge 10 ]; then echo "$year"; else echo "$((year - 1))"; fi
}

# The season being projected, as a start year: the one about to be played, or the one underway.
# That is a different question from the one above — through the summer the last season with games
# in it is already history while the season everyone is drafting for is the next one, so the
# cutover is July rather than October. Derived rather than configured, like the ingest season.
#
# This must agree with the BFF's PROJECTION_SEASON (application.yaml, `projection.season`), which
# is what the app asks the service for. Projecting a season nobody requests is invisible, and the
# failure is silent on both sides: the API answers 200 with an empty list.
target_season() {
  local year month
  year=$(date -u +%Y); month=$(date -u +%m)
  if [ "$((10#$month))" -ge 7 ]; then echo "$year"; else echo "$((year - 1))"; fi
}

# In season: the season with games in it is the season being projected, which runs from the
# morning after opening night to the end of June. The steps that read the season underway run only
# then; see the top of this file. Reads SEASON and TARGET, so the NHL is asked once a night.
in_season() {
  [ "$SEASON" = "$TARGET" ]
}

# A deploy replaces the container underneath a running step, and it goes wrong in two ways.
#
# The loud one: docker kills the exec with 137. That is not a failure of the work, it is the work
# being interrupted, and the timer would not try again until tomorrow.
#
# The quiet one, and the reason this helper takes a `marker`: if the container is *removed* rather
# than killed, `docker exec` into it **exits 0 and prints nothing at all**. By exit status that is
# indistinguishable from a clean run, so the sync logs a success, reports nothing to Sentry, and
# changes no data — which is precisely the silent no-op this whole file exists to prevent. It has
# happened: a `projection rosters` pass landed in the middle of a deploy, exited 0, and left the
# store exactly as it found it.
#
# So a step counts as done when it *says* so. Every one of them ends by printing a summary line,
# and `marker` is the fixed text at the front of it. Anything else - a bad status, or a status of
# zero with no summary - is treated as the container having gone away: looked up again, retried
# once, and reported as a failure if the second attempt does not say it worked either.
run_step() {
  local description="$1" marker="$2"
  shift 2  # what is left is the command to run *inside* the container
  local output status
  log "$description"
  output=$(docker exec "$CID" "$@" 2>&1)
  status=$?
  if ! step_worked "$status" "$output" "$marker"; then
    log "  no '${marker}' line (status ${status}) — a deploy most likely; looking the container up again"
    sleep 30
    CID="$(container_for "$SERVICE")"
    if [ -z "$CID" ]; then
      log "  FAILED: no container after the retry wait"
      send_sentry error "projection-sync: ${description} lost its container to a deploy"
      failed=1
      return
    fi
    output=$(docker exec "$CID" "$@" 2>&1)
    status=$?
  fi
  if step_worked "$status" "$output" "$marker"; then
    log "  $output"
  else
    log "  FAILED (status ${status}): ${output:-<no output at all>}"
    send_sentry error "projection-sync: ${description} failed"
    failed=1
  fi
}

# Exit zero *and* the summary line the command prints when it has done its work.
step_worked() {
  [ "$1" -eq 0 ] && printf '%s' "$2" | grep -qF -- "$3"
}

FIND_ONLY=0
if [ "${1:-}" = "--find-container" ]; then
  FIND_ONLY=1
  send_sentry() { :; }  # somebody is at the terminal reading the answer
fi

# Without the DSN file every failure below reaches the journal and nothing else. health-monitor.sh
# falls back to a DSN scavenged from a container; this does not, so say so on every run.
[ -s "$DSN_FILE" ] || log "WARNING: no ${DSN_FILE}; failures will not reach Sentry"

SERVICES="$(projection_services)"
case "$(printf '%s' "$SERVICES" | grep -c .)" in
  0)
    log "no running container has a Coolify service name ending in ${SERVICE_SUFFIX}; nothing to do"
    send_sentry error "projection-sync: no projection-service container found"
    exit 1 ;;
  1)
    SERVICE="$SERVICES" ;;
  *)
    log "more than one Coolify service ends in ${SERVICE_SUFFIX} ($(echo $SERVICES)); refusing to guess"
    send_sentry error "projection-sync: more than one projection-service on this host"
    exit 1 ;;
esac

CID="$(container_for "$SERVICE")"
if [ -z "$CID" ]; then
  log "${SERVICE} has no running container; nothing to do"
  send_sentry error "projection-sync: no projection-service container found"
  exit 1
fi

if [ "$FIND_ONLY" = 1 ]; then
  echo "$SERVICE $CID"
  exit 0
fi

SEASON="$(current_season)"
TARGET="$(target_season)"
failed=0

# The second argument of each step is the front of the line that command prints when it has done
# its work. It is what tells a real run from a `docker exec` into a container that has just been
# taken out from under it, which exits zero and says nothing. Keep these in step with `cli.py`:
# they are strings on both sides and nothing checks that they still agree.

# Rosters first. It is the cheap half and the half that fixes a wrong rookie marker, so it should
# not be held hostage to the ingest that follows it failing.
run_step "projection rosters" "Swept " projection rosters

run_step "projection ingest --season ${SEASON}" "Ingested seasons" \
  projection ingest --season "$SEASON"

# The season underway, in season only. Game logs after the ingest, because they are fetched for the
# player-seasons it has just recorded, so a call-up's games arrive the night he does. The schedule
# before the projection, because the projection counts return dates on it. Neither failure is
# fatal: each restates its rows in one transaction, so a failed night leaves yesterday's, and a
# store with no schedule at all falls back to last season's calendar, which is where it started.
if in_season; then
  run_step "projection game-logs --season ${SEASON}" "Game logs for" \
    projection game-logs --season "$SEASON"
  run_step "projection schedule --season ${TARGET}" "Scheduled " \
    projection schedule --season "$TARGET"
else
  log "out of season (${SEASON} has the games, ${TARGET} is projected): no game logs, no schedule"
fi

# Injuries before the projection, because the projection reads them. Its own failure is not
# fatal to the run: an injury table one day stale is a smaller error than no re-projection at
# all, and the model treats a player it knows nothing about as fit, which is what it did before
# this step existed.
run_step "projection injuries" "ESPN reports " projection injuries

# Lines after injuries and before the projection, because the projection reads them. Its failure is
# not fatal: the model reads the newest sweep for a fortnight, so a missed night changes nothing a
# user sees. A sweep that stops for 14 days does - every lineup input switches off at once, and
# nothing says so - which is why it runs here every night and not by hand.
run_step "projection lines" "Read " projection lines

# Re-project even if the steps above failed. The model reads the store rather than the fetch, so
# the worst case is that it reproduces yesterday's numbers — while skipping it after a failed
# fetch would strand every earlier day's data behind a stale projection for no gain.
run_step "projection project --season ${TARGET}" "Projected " \
  projection project --season "$TARGET"

exit "$failed"
