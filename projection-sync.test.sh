#!/usr/bin/env bash
# Exercise `run_step` against a stubbed docker, since the real thing only misbehaves when a
# deploy lands on top of it - which is not a thing you can arrange to watch.
#
#   ./projection-sync.test.sh
#
# Nothing runs this for you: the repo has no CI. Run it by hand after touching `run_step`, which
# has now been got wrong twice - once by rewriting the command's own arguments, and once by
# trusting an exit status that a removed container hands back as zero.
set -uo pipefail

SCRIPT="${1:-$(dirname "$0")/projection-sync.sh}"

# Lift the helpers out; the file's top level runs a real sync and cannot be sourced.
sed -n '/^run_step()/,/^}/p;/^step_worked()/,/^}/p' "$SCRIPT" > /tmp/helpers.sh
. /tmp/helpers.sh

# `run_step` calls docker inside a command substitution, so a stub that counts in a variable
# counts in a subshell and loses it. Everything the stub records goes to a file instead.
STATE=$(mktemp -d)
log() { :; }
send_sentry() { echo x >> "$STATE/sentry"; }
container_for() { echo "$CONTAINER_AFTER_LOOKUP"; }
APP_UUID=stub
CONTAINER_AFTER_LOOKUP=cid2
sleep() { :; }   # no real waiting in a test

# The stub records what it was asked to run, and answers from a queue of scripted attempts.
docker() {
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
# `target_season` and `in_season` and a stubbed clock. July to September must stay the run it was.
echo "== in season is October to June, and never July to September =="
SEASON_HELPERS=$(mktemp)
sed -n '/^current_season()/,/^}/p;/^target_season()/,/^}/p;/^in_season()/,/^}/p' "$SCRIPT" \
  > "$SEASON_HELPERS"
. "$SEASON_HELPERS"
date() { case "$*" in *%Y*) echo "$FAKE_YEAR" ;; *%m*) echo "$FAKE_MONTH" ;; esac; }
for when in "2026 07 no" "2026 09 no" "2026 10 yes" "2026 12 yes" "2027 01 yes" "2027 06 yes"; do
  read -r FAKE_YEAR FAKE_MONTH expected <<< "$when"
  if in_season; then got=yes; else got=no; fi
  check "in season in ${FAKE_YEAR}-${FAKE_MONTH}" "$expected" "$got"
done
unset -f date

echo "== the in-season steps sit behind the gate =="
gated=$(sed -n '/^if in_season; then/,/^fi/p' "$SCRIPT")
for step in "projection game-logs" "projection schedule"; do
  if printf '%s' "$gated" | grep -qF -- "run_step \"$step"; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1)); echo "  FAIL '$step' does not run behind in_season"
  fi
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
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
