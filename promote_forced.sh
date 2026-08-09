#!/usr/bin/env bash
# Restricted forced-command for the "prod promote" SSH key. Install on the PROD server as
# /root/promote_forced.sh, chmod 700, with the matching public key pinned in
# /root/.ssh/authorized_keys:
#
#   command="/root/promote_forced.sh",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty ssh-ed25519 AAAA... prod-promote
#
# Invoked by each repo's promote-to-prod workflow as:  ssh root@prod "<repo> <sha> <vX.Y.Z>"
#
# HOW PRODUCTION IS ACTUALLY PINNED — measured, not assumed (2026-08-09)
# Coolify's "Commit SHA" field (git_commit_sha) is INERT on this instance. Setting it to an
# older commit and deploying builds the branch tip anyway; verified on staging-espn-service:
# pinned 2b4affe, Coolify built 06bc9a0 and logged "Importing …:master (commit sha 06bc9a0)".
# What IS honoured is git_branch. Put a TAG there and Coolify clones -b <tag>, lands in
# detached HEAD on the tagged commit and builds exactly that; same service, git_branch=v0.0.2
# built 2b4affe with master untouched.
#
# So a promotion moves git_branch to the release tag — an immutable ref. Any later deploy from
# any path (the Redeploy button, the API, a webhook) rebuilds that same tag rather than
# whatever master has become. That is the property production was missing when prod-web
# silently ended up running master in August 2026.
#
# Requires (one-time):
#   /root/.coolify_token        — Coolify API token.
#   /root/prod_app_uuids.txt    — whitespace-separated "repo  uuid" per line.
#   jq
set -euo pipefail

read -r REPO SHA VERSION REST <<< "${SSH_ORIGINAL_COMMAND:-}"

LOG=/root/promote_prod.log
log() { echo "[$(date -u +%FT%TZ)] $*" >> "$LOG"; }
reject() { echo "promote: $1" >&2; log "REJECTED: $1 (raw='${SSH_ORIGINAL_COMMAND:-}')"; exit 2; }

[ -z "${REST:-}" ] || reject "too many args"
case "$REPO" in
  fantasy-web|fantasy-bff|fantasy-db-service|fantasy-espn-service|fantasy-projection-service|fantasy-yahoo-service) ;;
  *) reject "unknown repo '${REPO:-}'" ;;
esac
[[ "$SHA" =~ ^[0-9a-f]{40}$ ]] || reject "bad commit sha"
[[ "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || reject "bad version"

UUID="$(awk -v r="$REPO" '$1==r{print $2}' /root/prod_app_uuids.txt 2>/dev/null || true)"
[ -n "${UUID:-}" ] || reject "no prod uuid for $REPO"

# tr -d, not cat: a token pasted from Windows carries a CR, which makes the Authorization
# header end in \r and nginx answer 400 before Coolify ever sees the request.
TOKEN="$(tr -d '\r\n' < /root/.coolify_token)"
BASE="http://localhost:8000/api/v1"   # Coolify runs on this host; skip Traefik and the IP gate.
api() { curl -fsS -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" "$@"; }

log "PROMOTE $REPO -> $VERSION ($SHA) uuid=$UUID"
echo "promoting $REPO -> $VERSION ($SHA) on app $UUID"

# Refuse to promote an app Coolify also deploys on its own. The application API exposes no
# auto-deploy flag, so look for its footprint: a webhook-triggered deployment means a push
# reached production without a release.
if api "$BASE/deployments/applications/$UUID" \
     | jq -e '[.deployments[]? | select(.is_webhook == true)] | length > 0' >/dev/null; then
  reject "$REPO has webhook-triggered deployments in production — turn auto-deploy off first"
fi

# 1. Move the app onto the release tag. git_commit_sha stays "HEAD" deliberately: it is the
#    exact configuration that was measured to work, and a value there would only be misleading.
api -X PATCH "$BASE/applications/$UUID" \
  -d "$(jq -nc --arg b "$VERSION" '{git_branch:$b, git_commit_sha:"HEAD"}')" >/dev/null

# 2. Verify the move stuck BEFORE deploying anything.
GOT_BRANCH="$(api "$BASE/applications/$UUID" | jq -r '.git_branch // ""')"
if [ "$GOT_BRANCH" != "$VERSION" ]; then
  reject "branch did not move to $VERSION (still '$GOT_BRANCH') — NOT deploying"
fi

# 3. Stamp the version. PATCH updates the existing variable in place and preserves its flags
#    (measured: is_buildtime survives). The old set_env.py deleted and recreated instead, which
#    discards whatever flags a variable carried and relies on Coolify's defaults — fine by luck
#    today, silent breakage the day a default changes. fantasy-web in particular needs
#    APP_VERSION at BUILD time: it is baked into the Angular bundle.
set_env() {
  api -X PATCH "$BASE/applications/$UUID/envs" \
    -d "$(jq -nc --arg k "$1" --arg v "$2" '{key:$k, value:$v}')" >/dev/null \
    || reject "could not set $1 — is it pre-created on the app? (fantasy-web needs APP_VERSION as BUILD-TIME)"
}
set_env APP_VERSION "$VERSION"
set_env SENTRY_RELEASE "$VERSION"

# 4. Deploy.
DEPLOYMENT_UUID="$(api -X POST "$BASE/deploy?uuid=$UUID&force=false" \
  | jq -r '.deployments[0].deployment_uuid // ""')"
[ -n "$DEPLOYMENT_UUID" ] || reject "deploy did not return a deployment uuid"
echo "deployment $DEPLOYMENT_UUID queued"

# 5. Wait for it.
STATUS=""
for _ in $(seq 1 180); do
  STATUS="$(api "$BASE/deployments/$DEPLOYMENT_UUID" | jq -r '.status // ""')"
  case "$STATUS" in
    finished) break ;;
    failed|cancelled-by-user) log "FAILED $REPO $VERSION: deployment $STATUS"; echo "failed: deployment ended as '$STATUS'" >&2; exit 1 ;;
  esac
  sleep 5
done
if [ "$STATUS" != "finished" ]; then
  log "FAILED $REPO $VERSION: deployment timed out (last '$STATUS')"
  echo "failed: deployment did not finish within 15 minutes (last status '$STATUS')" >&2; exit 1
fi

# 6. Assert what was BUILT. The deployment record's .commit field is not trustworthy — it
#    echoes git_commit_sha, so it reads "HEAD" here — but the build log contains the commit
#    git actually checked out. That is the only honest source.
BUILD_LOG="$(api "$BASE/deployments/$DEPLOYMENT_UUID" | jq -r '.logs' | jq -r '.[]?.output // empty')"
if ! grep -qF "$SHA" <<< "$BUILD_LOG"; then
  log "FAILED $REPO $VERSION: build log does not mention $SHA"
  echo "FAILED: production did not build $SHA — it is NOT on $VERSION. Investigate before shipping again." >&2
  echo "$BUILD_LOG" | grep -iE 'importing|starting deployment' | head -3 >&2
  exit 1
fi

# 7. The branch must still be the tag afterwards.
GOT_BRANCH="$(api "$BASE/applications/$UUID" | jq -r '.git_branch // ""')"
[ "$GOT_BRANCH" = "$VERSION" ] || reject "branch drifted during deploy (now '$GOT_BRANCH')"

log "OK $REPO -> $VERSION ($SHA) verified"
echo "ok: $REPO production -> $VERSION ($SHA), verified against the build log"
