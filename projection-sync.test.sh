#!/usr/bin/env bash
# Exercise `run_step` and the container lookup against a stubbed docker, since the real thing only
# misbehaves when a deploy lands on top of it - which is not a thing you can arrange to watch.
#
#   PROJECTION_CLI=<fantasy-projection-service>/src/projection/cli.py ./projection-sync.test.sh
#
# Nothing runs this for you: the repo has no CI. Run it by hand after touching the script. `run_step`
# has now been got wrong twice - once by rewriting the command's own arguments, and once by
# trusting an exit status that a removed container hands back as zero. Without PROJECTION_CLI the
# marker check at the end is skipped (it says so), because a worktree has no service checkout.
set -uo pipefail

SCRIPT="${1:-$(dirname "$0")/projection-sync.sh}"

# Lift the helpers out; the file's top level runs a real sync and cannot be sourced.
HELPERS=$(mktemp)
sed -n '/^run_step()/,/^}/p;/^step_worked()/,/^}/p;/^projection_services()/,/^}/p;/^container_for()/,/^}/p;/^report_failure()/,/^}/p;/^plan_attempt()/,/^}/p;/^record_run()/,/^}/p' \
  "$SCRIPT" > "$HELPERS"
. "$HELPERS"
# The step cases below are the retry's: a failure there is one nobody will try again, so it is
# reported. The morning's quiet first attempt has cases of its own further down.
ATTEMPT=2
SERVICE_SUFFIX="$(sed -n 's/^SERVICE_SUFFIX=//p' "$SCRIPT")"

# `run_step` calls docker inside a command substitution, so a stub that counts in a variable
# counts in a subshell and loses it. Everything the stub records goes to a file instead.
STATE=$(mktemp -d)
log() { :; }
send_sentry() { echo x >> "$STATE/sentry"; }
sleep() { :; }   # no real waiting in a test

# `docker ps` answers from CONTAINERS, one "id service-name health" row per running container
# ("-" for a container Coolify did not label). It honours exactly the filters and formats the
# script uses, so a lookup that asks for something else gets nothing back and fails its check.
docker_ps() {
  local label="" healthy=0 fmt="" id name health
  while [ $# -gt 0 ]; do
    case "$1" in
      --filter)
        case "$2" in
          label=coolify.serviceName=*) label="${2#label=coolify.serviceName=}" ;;
          health=healthy) healthy=1 ;;
          *) return 1 ;;
        esac
        shift 2 ;;
      --format) fmt="$2"; shift 2 ;;
      -q) fmt='{{.ID}}'; shift ;;
      *) return 1 ;;
    esac
  done
  while read -r id name health; do
    [ -z "$id" ] && continue
    [ "$name" = "-" ] && name=""
    [ -n "$label" ] && [ "$name" != "$label" ] && continue
    [ "$healthy" = 1 ] && [ "$health" != healthy ] && continue
    case "$fmt" in
      '{{.ID}}') echo "$id" ;;
      '{{.Label "coolify.serviceName"}}') echo "$name" ;;
      *) return 1 ;;
    esac
  done <<< "$CONTAINERS"
}

# `docker exec` records what it was asked to run, and answers from a queue of scripted attempts.
docker() {
  if [ "$1" = ps ]; then shift; docker_ps "$@"; return; fi
  shift 2  # "exec" and the container id
  echo "$*" > "$STATE/args"
  echo x >> "$STATE/attempts"
  local n spec
  n=$(wc -l < "$STATE/attempts")
  spec="${ATTEMPTS[$((n - 1))]}"
  printf '%s' "${spec#*:}"
  return "${spec%%:*}"
}

pass=0; fail=0
check() { # name expected actual
  if [ "$2" = "$3" ]; then pass=$((pass + 1)); else
    fail=$((fail + 1)); echo "  FAIL $1: expected '$2', got '$3'"
  fi
}

# The lookup, with the real `projection_services` and `container_for`. The service names are the
# ones Coolify gives each host's app; the neighbours are there to be ignored.
echo "== staging: the service is found by its own name, and a deploy's healthy container wins =="
CONTAINERS="c-bff staging-bff healthy
c-pg staging-projection-postgres healthy
c-new staging-projection-service starting
c-old staging-projection-service healthy
c-coolify - healthy"
check "one service" "staging-projection-service" "$(projection_services)"
check "the healthy one of two" "c-old" "$(container_for staging-projection-service)"

echo "== production: the same file finds prod's name =="
CONTAINERS="c-web prod-web healthy
c-proj prod-projection-service healthy
c-projdb prod-projection-postgres healthy"
check "one service" "prod-projection-service" "$(projection_services)"
check "its container" "c-proj" "$(container_for prod-projection-service)"

echo "== mid-deploy with nothing healthy yet: fall back to the one that is there =="
CONTAINERS="c-boot prod-projection-service starting"
check "the only container" "c-boot" "$(container_for prod-projection-service)"

echo "== not a suffix match: a name that merely contains it is ignored =="
CONTAINERS="c-x prod-projection-service-old healthy
c-y - healthy"
check "no service" "" "$(projection_services)"

echo "== two apps named like it: both are reported, so the script can refuse =="
CONTAINERS="c-a prod-projection-service healthy
c-b copy-projection-service healthy
c-c prod-projection-service starting"
check "two distinct services" "copy-projection-service prod-projection-service" "$(echo $(projection_services))"

echo "== no Coolify application UUID is written into the script =="
# The class of bug this replaced: a host's UUID baked into a file installed on more than one host.
for conf in "$(dirname "$SCRIPT")"/health-monitor.*.conf; do
  while read -r name _ target _; do
    case "$name" in ''|\#*) continue ;; esac
    if grep -qF -- "$target" "$SCRIPT"; then
      fail=$((fail + 1)); echo "  FAIL ${name}'s UUID from $(basename "$conf") appears in the script"
    else
      pass=$((pass + 1))
    fi
  done < "$conf"
done

container_for() { echo "$CONTAINER_AFTER_LOOKUP"; }
SERVICE=stub
CONTAINER_AFTER_LOOKUP=cid2

run_case() { # name  attempts...
  local name="$1"; shift
  ATTEMPTS=("$@")
  : > "$STATE/attempts"; : > "$STATE/args"; : > "$STATE/sentry"
  failed=0; CID=cid1
  run_step "$name" "Swept " projection rosters --sleep 0.1
  echo "$name|$failed|$(wc -l < "$STATE/attempts" | tr -d " ")|$(wc -l < "$STATE/sentry" | tr -d " ")|$(cat "$STATE/args")"
}

echo "== a clean run =="
result=$(run_case clean "0:Swept 32 rosters holding 1688 players")
IFS='|' read -r _ f a s args <<< "$result"
check "no failure" 0 "$f"; check "one attempt" 1 "$a"; check "no sentry" 0 "$s"
check "argv intact" "projection rosters --sleep 0.1" "$args"

echo "== killed with 137, then fine =="
result=$(run_case killed "137:" "0:Swept 32 rosters holding 1688 players")
IFS='|' read -r _ f a s args <<< "$result"
check "no failure" 0 "$f"; check "two attempts" 2 "$a"; check "no sentry" 0 "$s"
check "argv intact on the retry" "projection rosters --sleep 0.1" "$args"

echo "== the silent one: exit 0, no output, then fine =="
result=$(run_case silent "0:" "0:Swept 32 rosters holding 1688 players")
IFS='|' read -r _ f a s _ <<< "$result"
check "no failure" 0 "$f"; check "two attempts" 2 "$a"; check "no sentry" 0 "$s"

echo "== silent twice: this is the bug that shipped =="
result=$(run_case silent_twice "0:" "0:")
IFS='|' read -r _ f a s _ <<< "$result"
check "reported as failed" 1 "$f"; check "two attempts" 2 "$a"; check "sentry told" 1 "$s"

echo "== exit 0 but a different command's summary =="
result=$(run_case wrong_line "0:Projected 2128 skaters" "0:Projected 2128 skaters")
IFS='|' read -r _ f _ s _ <<< "$result"
check "reported as failed" 1 "$f"; check "sentry told" 1 "$s"

echo "== a real failure is not retried into a pass =="
result=$(run_case broken "1:Traceback (most recent call last)" "1:Traceback")
IFS='|' read -r _ f _ s _ <<< "$result"
check "reported as failed" 1 "$f"; check "sentry told" 1 "$s"

echo "== the container never comes back =="
CONTAINER_AFTER_LOOKUP=""
result=$(run_case gone "137:" "0:Swept 32 rosters")
IFS='|' read -r _ f a s _ <<< "$result"
check "reported as failed" 1 "$f"; check "gave up after one attempt" 1 "$a"; check "sentry told" 1 "$s"

echo "== the lines step, whose summary line starts differently =="
CONTAINER_AFTER_LOOKUP=cid2
ATTEMPTS=("0:Read 32 clubs, 1237 assignments, 1237 matched to the store")
: > "$STATE/attempts"; : > "$STATE/args"; : > "$STATE/sentry"
failed=0; CID=cid1
run_step lines "Read " projection lines
check "no failure" 0 "$failed"
check "one attempt" 1 "$(wc -l < "$STATE/attempts" | tr -d ' ')"

# The gate in front of the in-season steps, with the script's own `current_season`,
# `target_season` and `in_season`, a stubbed clock and a stubbed answer from the service. The season
# underway is the NHL's: 30 September 2026 is in 2026-27, where the old October rule said 2025-26.
echo "== in season runs from the morning after opening night to June =="
SEASON_HELPERS=$(mktemp)
sed -n '/^current_season()/,/^}/p;/^target_season()/,/^}/p;/^in_season()/,/^}/p' "$SCRIPT" \
  > "$SEASON_HELPERS"
. "$SEASON_HELPERS"
date() { case "$*" in *%Y*) echo "$FAKE_YEAR" ;; *%m*) echo "$FAKE_MONTH" ;; esac; }
docker() { [ -z "$UNDERWAY" ] || printf 'Season underway: %s, opened 2026-09-29\n' "$UNDERWAY"; }
# year month what-the-service-says expected ("-" is no answer at all)
for when in "2026 09 2025 no" "2026 09 2026 yes" "2026 10 2026 yes" "2027 06 2026 yes" \
  "2027 07 2026 no" "2026 10 - yes" "2026 09 - no"; do
  read -r FAKE_YEAR FAKE_MONTH UNDERWAY expected <<< "$when"
  [ "$UNDERWAY" = - ] && UNDERWAY=""
  : > "$STATE/sentry"
  SEASON=$(current_season 2>/dev/null); TARGET=$(target_season)
  if in_season; then got=yes; else got=no; fi
  check "in season on ${FAKE_YEAR}-${FAKE_MONTH}, service says '${UNDERWAY}'" "$expected" "$got"
  if [ -z "$UNDERWAY" ]; then
    check "a guessed season is reported on ${FAKE_YEAR}-${FAKE_MONTH}" 1 \
      "$(wc -l < "$STATE/sentry" | tr -d ' ')"
  fi
done
unset -f date docker

echo "== the game logs sit behind the gate, and the schedule runs every night =="
gated=$(sed -n '/^if in_season; then/,/^fi/p' "$SCRIPT")
if printf '%s' "$gated" | grep -qF -- 'run_step "projection game-logs'; then
  pass=$((pass + 1))
else
  fail=$((fail + 1)); echo "  FAIL the game logs do not run behind in_season"
fi
if printf '%s' "$gated" | grep -qF -- 'run_step "projection schedule'; then
  fail=$((fail + 1)); echo "  FAIL the schedule runs only in season; it has to run every night"
elif grep -qF -- 'run_step "projection schedule' "$SCRIPT"; then
  pass=$((pass + 1))
else
  fail=$((fail + 1)); echo "  FAIL the schedule step is gone"
fi

# The retry, with the script's own `plan_attempt`, `report_failure` and `record_run`, a state file
# of the test's own and a stubbed clock.
echo "== a failed morning is retried once in the afternoon, and only then reported =="
PROJECTION_SYNC_STATE="$STATE/last-run"
STATE_FILE="$PROJECTION_SYNC_STATE"
date() { case "$*" in *%F*) echo "$FAKE_DAY" ;; *) command date "$@" ;; esac; }
FAKE_DAY=2026-09-30
plan() { # state-line-or-dash mode -> "attempt|sentry-count"
  : > "$STATE/sentry"
  if [ "$1" = - ]; then rm -f "$STATE_FILE"; else echo "$1" > "$STATE_FILE"; fi
  echo "$(plan_attempt "$2")|$(wc -l < "$STATE/sentry" | tr -d ' ')"
}
check "a first run ever is attempt 1" "1|0" "$(plan - run)"
check "the morning after a good day is attempt 1" "1|0" "$(plan '2026-09-29 1 ok' run)"
check "a retry after a failed morning is attempt 2" "2|0" "$(plan '2026-09-30 1 failed' retry)"
check "a retry after a good morning has nothing to do" "|0" "$(plan '2026-09-30 1 ok' retry)"
check "a retry never makes a third attempt" "|0" "$(plan '2026-09-30 2 failed' retry)"
check "a retry does not pick up yesterday's failure" "|0" "$(plan '2026-09-29 1 failed' retry)"
check "a failure nobody retried is reported by the next run" "1|1" "$(plan '2026-09-29 1 failed' run)"
check "a failure the retry already reported is not reported twice" "1|0" \
  "$(plan '2026-09-29 2 failed' run)"

ATTEMPT=1; : > "$STATE/sentry"
report_failure "projection-sync: projection ingest --season 2026 failed"
check "a first attempt's failure stays out of Sentry" 0 "$(wc -l < "$STATE/sentry" | tr -d ' ')"
record_run failed
check "and is written down for the retry" "2026-09-30 1 failed" "$(cat "$STATE_FILE")"

ATTEMPT=2; : > "$STATE/sentry"
report_failure "projection-sync: projection ingest --season 2026 failed"
check "the retry's failure goes to Sentry" 1 "$(wc -l < "$STATE/sentry" | tr -d ' ')"
record_run ok
check "and a good retry is written down as the day's outcome" "2026-09-30 2 ok" "$(cat "$STATE_FILE")"
unset -f date

echo "== the afternoon timer runs the retry =="
DIR="$(dirname "$SCRIPT")"
check "the retry service passes --retry" 1 \
  "$(grep -c '^ExecStart=/root/projection-sync.sh --retry$' "$DIR/projection-sync-retry.service")"
check "the retry timer fires at 16:30 UTC" 1 \
  "$(grep -c '^OnCalendar=\*-\*-\* 16:30:00 UTC$' "$DIR/projection-sync-retry.timer")"
for unit in projection-sync.service projection-sync-retry.service; do
  check "$unit keeps its state where the script looks" 1 \
    "$(grep -c '^StateDirectory=projection-sync$' "$DIR/$unit")"
done

# The gap `run_step`'s own comment names: the markers are strings on both sides and nothing
# checked that they still agree. A step whose marker no longer matches what the command prints
# reports a failure on every clean run, which is the same alarm-that-cries-wolf this file exists
# to avoid — so check them against the CLI that prints them.
echo "== every marker still matches something the CLI prints =="
CLI="${PROJECTION_CLI:-$(dirname "$SCRIPT")/fantasy-projection-service/src/projection/cli.py}"
if [ ! -f "$CLI" ]; then
  # The service is a separate repo, ignored by this one, so a worktree of the workspace does not
  # have it. Say so rather than passing quietly.
  echo "  SKIPPED: no cli.py at $CLI (set PROJECTION_CLI to point at one)"
else
  while IFS= read -r marker; do
    if grep -qF -- "$marker" "$CLI"; then
      pass=$((pass + 1))
    else
      fail=$((fail + 1))
      echo "  FAIL marker '$marker' appears nowhere in cli.py; the step would fail on a clean run"
    fi
  done < <(grep -o 'run_step "[^"]*" "[^"]*"' "$SCRIPT" | sed 's/.*" "//;s/"$//')
  # Not a step, but read the same way: the season is taken off this line's front.
  if grep -qF -- 'Season underway: ' "$CLI"; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "  FAIL 'Season underway: ' appears nowhere in cli.py; every night would guess the season"
  fi
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
