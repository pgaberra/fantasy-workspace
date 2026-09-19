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
# The game logs run only in season, from the morning after opening night to the end of June, when
# the season with games in it is the season being projected. The schedule runs every night, for the
# season being projected, including a summer's coming season once the NHL has published it. Until
# they ran, the store's newest calendar was last season's game logs moved forward a year: a 2026-27
# return date was counted against
# 2025-26's three-week Olympic break, and Who's hot had no games at all for the season underway.
# A return date is counted on the schedule and not on the logs, because the logs stop at last
# night. Out of season the game logs do not run: the season with games is over and logged.
#
# A failed night is retried once, in the afternoon, before anybody is told. Most failures here fix
# themselves within hours (MoneyPuck has not published a new season's file the morning after
# opening night, a source is briefly down, a deploy lands on a step twice), and a Sentry alert for
# each one would train everyone to ignore the alert that matters. So the morning run keeps its
# failures to the journal, projection-sync-retry.timer runs this again with `--retry` at 16:30 UTC,
# that run does the whole sync again only if the morning failed, and whatever still fails then goes
# to Sentry. A morning failure nobody retried (the retry timer missing, or not firing) is reported
# by the next run, so the quiet morning is never quiet for long. See `plan_attempt`.
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
#   projection-sync.sh                    run the sync (the morning timer, or by hand)
#   projection-sync.sh --retry            run it again only if today's run failed (the afternoon timer)
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

# What the last run left behind, one line: its UTC date, which attempt it was, and ok or failed.
# The afternoon retry reads it to decide whether there is anything to retry. The directory is the
# units' StateDirectory; the variable only exists so the test can point it somewhere else.
STATE_FILE="${PROJECTION_SYNC_STATE:-/var/lib/projection-sync/last-run}"

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
      report_failure "projection-sync: ${description} lost its container to a deploy"
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
    report_failure "projection-sync: ${description} failed"
    failed=1
  fi
}

# Exit zero *and* the summary line the command prints when it has done its work.
step_worked() {
  [ "$1" -eq 0 ] && printf '%s' "$2" | grep -qF -- "$3"
}

# Which attempt this run is today: 1 for the morning run (or one started by hand), 2 for an
# afternoon retry of a morning that failed, and nothing at all for a retry with nothing to retry.
# One retry and no more: a second failure is reported, and the next morning starts again at 1.
#
# A failed first attempt that no retry followed is reported here, by the next run, before it does
# anything else. Without that, a missing or broken retry timer would turn every failure into one
# nobody hears about, which is the silent night this whole file exists to prevent.
plan_attempt() { # mode (run|retry)
  local mode="$1" today last_date="" last_attempt="" last_outcome=""
  today=$(date -u +%F)
  [ -r "$STATE_FILE" ] && read -r last_date last_attempt last_outcome < "$STATE_FILE"
  if [ "$mode" = retry ]; then
    if [ "$last_date" = "$today" ] && [ "$last_attempt" = 1 ] && [ "$last_outcome" = failed ]; then
      echo 2
    fi
    return 0
  fi
  if [ "$last_outcome" = failed ] && [ "$last_attempt" = 1 ] && [ "$last_date" != "$today" ]; then
    send_sentry error "projection-sync: the run on ${last_date} failed and no retry followed it"
  fi
  echo 1
}

# A failure on the first attempt goes to the journal and waits for the retry; one on the retry goes
# to Sentry, since there is no third try to wait for. Unset (`--find-container`) reports as a retry.
report_failure() { # message
  if [ "${ATTEMPT:-2}" -ge 2 ]; then
    send_sentry error "$1"
  else
    log "  not sent to Sentry: the afternoon retry reports it if it fails again"
  fi
}

# Written at the end of every sync, so the retry knows what happened. A state file that cannot be
# written means a failure will never be retried, and that is itself worth hearing about.
record_run() { # outcome (ok|failed)
  mkdir -p "$(dirname "$STATE_FILE")" 2>/dev/null
  if ! echo "$(date -u +%F) ${ATTEMPT} $1" > "$STATE_FILE" 2>/dev/null; then
    log "WARNING: could not write ${STATE_FILE}; a failed run will not be retried"
    send_sentry warning "projection-sync: could not write its state file, so failures are not retried"
  fi
}

FIND_ONLY=0
MODE=run
case "${1:-}" in
  --find-container)
    FIND_ONLY=1
    send_sentry() { :; } ;;  # somebody is at the terminal reading the answer
  --retry)
    MODE=retry ;;
esac

# Without the DSN file every failure below reaches the journal and nothing else. health-monitor.sh
# falls back to a DSN scavenged from a container; this does not, so say so on every run.
[ -s "$DSN_FILE" ] || log "WARNING: no ${DSN_FILE}; failures will not reach Sentry"

# Before any container is looked for: a retry with nothing to retry has nothing to look for.
if [ "$FIND_ONLY" = 0 ]; then
  ATTEMPT="$(plan_attempt "$MODE")"
  if [ -z "$ATTEMPT" ]; then
    log "retry: nothing to retry (today's run did not fail, or has been retried already)"
    exit 0
  fi
  [ "$ATTEMPT" = 2 ] && log "retrying today's failed run; whatever fails now goes to Sentry"
fi

# The lookup failing ends the run, and counts as a failed run like any other.
give_up() { # message sentry-message
  log "$1"
  report_failure "$2"
  [ "$FIND_ONLY" = 1 ] || record_run failed
  exit 1
}

SERVICES="$(projection_services)"
case "$(printf '%s' "$SERVICES" | grep -c .)" in
  0)
    give_up "no running container has a Coolify service name ending in ${SERVICE_SUFFIX}; nothing to do" \
      "projection-sync: no projection-service container found" ;;
  1)
    SERVICE="$SERVICES" ;;
  *)
    give_up "more than one Coolify service ends in ${SERVICE_SUFFIX} ($(echo $SERVICES)); refusing to guess" \
      "projection-sync: more than one projection-service on this host" ;;
esac

CID="$(container_for "$SERVICE")"
if [ -z "$CID" ]; then
  give_up "${SERVICE} has no running container; nothing to do" \
    "projection-sync: no projection-service container found"
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

# The season underway's game logs, in season only, and after the ingest, because they are fetched
# for the player-seasons it has just recorded, so a call-up's games arrive the night he does. Its
# failure is not fatal: the logs are restated in one transaction, so a failed night leaves
# yesterday's.
if in_season; then
  run_step "projection game-logs --season ${SEASON}" "Game logs for" \
    projection game-logs --season "$SEASON"
else
  log "out of season (${SEASON} has the games, ${TARGET} is projected): no game logs"
fi

# The published schedule of the season being projected, every night and before the projection,
# because the projection counts return dates on it and #161's lineup gate reads opening night off
# it. In the summer that is the coming season's, which the NHL publishes some time in July; until
# it has, the step says so and succeeds (projection-service #164), and the projection falls back
# to last season's calendar. Not fatal either: a failed night leaves yesterday's schedule.
run_step "projection schedule --season ${TARGET}" "Scheduled " \
  projection schedule --season "$TARGET"

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

if [ "$failed" = 0 ]; then record_run ok; else record_run failed; fi
exit "$failed"
