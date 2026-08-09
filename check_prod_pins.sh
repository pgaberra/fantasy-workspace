#!/usr/bin/env bash
# Guard against production silently following master.
#
# Coolify builds  $commit ?: ($application->git_commit_sha ?: 'HEAD'), so a prod app whose
# git_commit_sha is empty or 'HEAD' deploys the branch tip on the next redeploy — no promote,
# no release, no warning. Auto-deploy does the same thing on every merge. Both are invisible
# in the UI unless you go looking, so this checks for them.
#
# Run on the PROD server (it holds /root/.coolify_token). Exits non-zero on any violation, so
# it works as a cron job:
#   0 7 * * * /root/check_prod_pins.sh || mail -s "SlapStat: prod pin drift" you@example.com
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

  APP="$(curl -fsS -H "Authorization: Bearer $TOKEN" "$BASE/applications/$UUID" || true)"
  if [ -z "$APP" ] || [ "$(jq -r '.uuid // ""' <<< "$APP")" = "" ]; then
    echo "ERROR  $REPO: no such application ($UUID) — stale entry in prod_app_uuids.txt?"
    PROBLEMS=$((PROBLEMS + 1))
    continue
  fi

  SHA="$(jq -r '.git_commit_sha // ""' <<< "$APP")"
  BRANCH="$(jq -r '.git_branch // ""' <<< "$APP")"

  DEPLOYMENTS="$(curl -fsS -H "Authorization: Bearer $TOKEN" "$BASE/deployments/applications/$UUID" || echo '{}')"
  LAST_COMMIT="$(jq -r '.deployments[0].commit // ""' <<< "$DEPLOYMENTS")"
  WEBHOOKED="$(jq -r '[.deployments[]? | select(.is_webhook == true)] | length' <<< "$DEPLOYMENTS")"

  CLEAN=1
  if [ -z "$SHA" ] || [ "$SHA" = "HEAD" ]; then
    echo "UNPINNED  $REPO (branch '$BRANCH') — next deploy would build the tip of '$BRANCH'"
    PROBLEMS=$((PROBLEMS + 1)); CLEAN=0
  fi
  # The application API exposes no auto-deploy flag, so look for its footprint instead.
  if [ "${WEBHOOKED:-0}" -gt 0 ]; then
    echo "AUTODEPLOY  $REPO — $WEBHOOKED webhook-triggered deployment(s); a push can reach production"
    PROBLEMS=$((PROBLEMS + 1)); CLEAN=0
  fi
  # What is running must be what was promoted. prod-web drifted exactly here in Aug 2026.
  if [ -n "$SHA" ] && [ -n "$LAST_COMMIT" ] && [ "$SHA" != "$LAST_COMMIT" ]; then
    echo "DRIFT  $REPO — pinned ${SHA:0:7} but last deployed ${LAST_COMMIT:0:7}"
    PROBLEMS=$((PROBLEMS + 1)); CLEAN=0
  fi
  [ "$CLEAN" = "1" ] && echo "ok  $REPO  branch=$BRANCH  sha=${SHA:0:7}"
done < /root/prod_app_uuids.txt

if [ "$PROBLEMS" -gt 0 ]; then
  echo
  echo "$PROBLEMS problem(s) found — production can move without a release."
  exit 1
fi
echo
echo "All production apps are pinned and will not follow a branch."
