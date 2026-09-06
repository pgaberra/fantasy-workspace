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

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
