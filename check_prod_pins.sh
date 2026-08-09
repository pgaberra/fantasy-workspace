#!/usr/bin/env bash
# Guard against production silently following a moving branch.
#
# Measured on this Coolify instance (2026-08-09): the "Commit SHA" field (git_commit_sha) is
# INERT — a deploy builds the tip of git_branch regardless of it. So the only thing keeping
# production still is git_branch pointing at an immutable release TAG. An app whose git_branch
# is "master" will rebuild whatever master has become the next time anyone redeploys it, with
# no release, no promotion and no warning. That is how prod-web ended up running master in
# August 2026 while its "pin" still read v0.83.0.
#
# Run on the PROD server (it holds /root/.coolify_token). Exits non-zero on any violation:
#   0 7 * * * /root/check_prod_pins.sh || mail -s "SlapStat: prod is not on a release" you@example.com
#
# Requires: /root/.coolify_token, /root/prod_app_uuids.txt, jq.
set -uo pipefail

TOKEN="$(cat /root/.coolify_token)"
BASE="http://localhost:8000/api/v1"
PROBLEMS=0

# prod_app_uuids.txt is whitespace-separated: "repo  uuid".
while read -r REPO UUID _; do
  [ -z "${REPO:-}" ] && continue
  case "$REPO" in \#*) continue ;; esac

  APP="$(curl -fsS -H "Authorization: Bearer $TOKEN" "$BASE/applications/$UUID" 2>/dev/null || true)"
  if [ -z "$(jq -r '.uuid // ""' <<< "${APP:-{\}}" 2>/dev/null)" ]; then
    echo "ERROR       $REPO — no such application ($UUID); stale entry in prod_app_uuids.txt?"
    PROBLEMS=$((PROBLEMS + 1))
    continue
  fi

  BRANCH="$(jq -r '.git_branch // ""' <<< "$APP")"
  DEPLOYMENTS="$(curl -fsS -H "Authorization: Bearer $TOKEN" "$BASE/deployments/applications/$UUID" 2>/dev/null || echo '{}')"
  WEBHOOKED="$(jq -r '[.deployments[]? | select(.is_webhook == true)] | length' <<< "$DEPLOYMENTS")"
  LAST_AT="$(jq -r '.deployments[0].created_at // "never"' <<< "$DEPLOYMENTS")"

  CLEAN=1
  if [[ ! "$BRANCH" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "UNRELEASED  $REPO — git_branch is '$BRANCH', not a release tag; a redeploy would build its tip"
    PROBLEMS=$((PROBLEMS + 1)); CLEAN=0
  fi
  if [ "${WEBHOOKED:-0}" -gt 0 ]; then
    echo "AUTODEPLOY  $REPO — $WEBHOOKED webhook-triggered deployment(s); a push can reach production"
    PROBLEMS=$((PROBLEMS + 1)); CLEAN=0
  fi
  [ "$CLEAN" = "1" ] && echo "ok          $REPO  $BRANCH  (last deployed $LAST_AT)"
done < /root/prod_app_uuids.txt

if [ "$PROBLEMS" -gt 0 ]; then
  echo
  echo "$PROBLEMS problem(s) — production can move without anyone publishing a release."
  exit 1
fi
echo
echo "Every production app is on a release tag and cannot follow a branch."
