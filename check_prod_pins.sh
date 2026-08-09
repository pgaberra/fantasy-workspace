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
BASE="https://coolify.slapstat.com/api/v1"
PROBLEMS=0

while IFS='=' read -r REPO UUID; do
  [ -z "${REPO:-}" ] && continue
  case "$REPO" in \#*) continue ;; esac

  APP="$(curl -fsS -H "Authorization: Bearer $TOKEN" "$BASE/applications/$UUID" || true)"
  if [ -z "$APP" ]; then
    echo "ERROR  $REPO: could not read application $UUID"
    PROBLEMS=$((PROBLEMS + 1))
    continue
  fi

  SHA="$(jq -r '.git_commit_sha // ""' <<< "$APP")"
  BRANCH="$(jq -r '.git_branch // ""' <<< "$APP")"
  AUTO="$(jq -r '.settings.is_auto_deploy_enabled // false' <<< "$APP")"

  if [ -z "$SHA" ] || [ "$SHA" = "HEAD" ]; then
    echo "UNPINNED  $REPO (branch '$BRANCH') — next deploy would build the tip of '$BRANCH'"
    PROBLEMS=$((PROBLEMS + 1))
  fi
  if [ "$AUTO" = "true" ]; then
    echo "AUTODEPLOY  $REPO — a merge to '$BRANCH' deploys straight to production"
    PROBLEMS=$((PROBLEMS + 1))
  fi
  if [ -n "$SHA" ] && [ "$SHA" != "HEAD" ] && [ "$AUTO" != "true" ]; then
    echo "ok  $REPO  branch=$BRANCH  sha=${SHA:0:7}"
  fi
done < /root/prod_app_uuids.txt

if [ "$PROBLEMS" -gt 0 ]; then
  echo
  echo "$PROBLEMS problem(s) found — production can move without a release."
  exit 1
fi
echo
echo "All production apps are pinned and will not follow a branch."
