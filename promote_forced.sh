#!/usr/bin/env bash
# Restricted forced-command for the "prod promote" SSH key (sibling of
# set_staging_version_forced.sh). Install on the PROD server as /root/promote_forced.sh,
# chmod 700, with the matching public key pinned in /root/.ssh/authorized_keys:
#
#   command="/root/promote_forced.sh",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty ssh-ed25519 AAAA... prod-promote
#
# Invoked by each repo's promote-to-prod workflow as:  ssh root@prod "<repo> <sha> <vX.Y.Z>"
#
# WHY THE VERIFICATION STEPS EXIST
# Coolify picks the commit to build as:  $commit ?: ($application->git_commit_sha ?: 'HEAD')
# and NEITHER the Redeploy button NOR the deploy API passes a commit. So an application whose
# git_commit_sha is empty or 'HEAD' silently builds the branch tip — that is how production
# drifted onto master in Aug 2026 (prod-web ran master while its pin still read v0.83.0).
# This script therefore refuses to deploy unless the pin is verifiably in place, and fails
# loudly if the commit that actually landed is not the one asked for.
#
# Requires (one-time):
#   /root/.coolify_token        — Coolify API token.
#   /root/prod_app_uuids.txt    — "repo=uuid" per line, e.g. fantasy-web=abc123.
#   jq                          — apt-get install -y jq.
set -euo pipefail

read -r REPO SHA VERSION _ <<< "${SSH_ORIGINAL_COMMAND:-}"

case "$REPO" in
  fantasy-web|fantasy-bff|fantasy-db-service|fantasy-espn-service|fantasy-projection-service|fantasy-yahoo-service) ;;
  *) echo "refused: unknown repo '$REPO'" >&2; exit 1 ;;
esac
if [[ ! "$SHA" =~ ^[0-9a-f]{40}$ ]]; then
  echo "refused: '$SHA' is not a full 40-char commit sha" >&2; exit 1
fi
if [[ ! "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "refused: bad version '$VERSION'" >&2; exit 1
fi

UUID="$(grep -E "^${REPO}=" /root/prod_app_uuids.txt 2>/dev/null | head -1 | cut -d= -f2 || true)"
if [ -z "$UUID" ]; then echo "refused: no prod UUID mapped for '$REPO'" >&2; exit 1; fi

TOKEN="$(cat /root/.coolify_token)"
BASE="https://coolify.slapstat.com/api/v1"

api() {
  curl -fsS -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" "$@"
}

echo "promoting $REPO -> $VERSION ($SHA) on app $UUID"

# 1. Pin the app: branch to the immutable tag, commit to the exact sha. The branch is
#    belt-and-braces — even a deploy that ignored the sha would resolve the tag, not master.
api -X PATCH "$BASE/applications/$UUID" \
  -d "$(jq -nc --arg b "$VERSION" --arg s "$SHA" '{git_branch:$b, git_commit_sha:$s}')" >/dev/null

# 2. Read it back and refuse to deploy unless the pin actually stuck.
APP="$(api "$BASE/applications/$UUID")"
GOT_SHA="$(jq -r '.git_commit_sha // ""' <<< "$APP")"
GOT_BRANCH="$(jq -r '.git_branch // ""' <<< "$APP")"
if [ "$GOT_SHA" != "$SHA" ] || [ "$GOT_BRANCH" != "$VERSION" ]; then
  echo "refused: pin did not stick (branch='$GOT_BRANCH' sha='$GOT_SHA') — NOT deploying" >&2
  exit 1
fi

# 3. Refuse to promote an app that Coolify would also deploy on its own. Auto-deploy on a
#    prod app means a merge to master can reach production without going through a release.
if [ "$(jq -r '.settings.is_auto_deploy_enabled // false' <<< "$APP")" = "true" ]; then
  echo "refused: auto-deploy is ON for $REPO in production — turn it off first" >&2
  exit 1
fi

# 4. Stamp the version. APP_VERSION must already exist on the app (Coolify's env PATCH cannot
#    set the build-time flag, and fantasy-web needs it at build time to bake it into the bundle).
set_env() {
  local key="$1" value="$2"
  api -X PATCH "$BASE/applications/$UUID/envs" \
    -d "$(jq -nc --arg k "$key" --arg v "$value" '{key:$k, value:$v}')" >/dev/null \
    || { echo "failed: could not set $key — is it pre-created on the app?" >&2; exit 1; }
}
set_env APP_VERSION "$VERSION"
set_env SENTRY_RELEASE "$VERSION"

# 5. Deploy.
DEPLOY="$(api "$BASE/deploy?uuid=$UUID")"
DEPLOYMENT_UUID="$(jq -r '.deployments[0].deployment_uuid // ""' <<< "$DEPLOY")"
if [ -z "$DEPLOYMENT_UUID" ]; then
  echo "failed: deploy did not return a deployment uuid: $DEPLOY" >&2; exit 1
fi
echo "deployment $DEPLOYMENT_UUID queued"

# 6. Wait for it, then assert that what landed is what we asked for.
STATUS=""
DEPLOYMENT=""
for _ in $(seq 1 180); do
  DEPLOYMENT="$(api "$BASE/deployments/$DEPLOYMENT_UUID" || true)"
  STATUS="$(jq -r '.status // ""' <<< "$DEPLOYMENT")"
  case "$STATUS" in
    finished) break ;;
    failed|cancelled-by-user) echo "failed: deployment ended as '$STATUS'" >&2; exit 1 ;;
  esac
  sleep 5
done
if [ "$STATUS" != "finished" ]; then
  echo "failed: deployment did not finish within 15 minutes (last status '$STATUS')" >&2; exit 1
fi

DEPLOYED_COMMIT="$(jq -r '.commit // ""' <<< "$DEPLOYMENT")"
if [ -n "$DEPLOYED_COMMIT" ] && [ "$DEPLOYED_COMMIT" != "$SHA" ]; then
  echo "FAILED: production deployed $DEPLOYED_COMMIT but $VERSION is $SHA" >&2
  echo "        prod is NOT on the version you promoted — investigate before shipping again" >&2
  exit 1
fi

# 7. The pin must still read the promoted commit after the deploy.
GOT_SHA="$(api "$BASE/applications/$UUID" | jq -r '.git_commit_sha // ""')"
if [ "$GOT_SHA" != "$SHA" ]; then
  echo "FAILED: pin drifted during deploy (now '$GOT_SHA', expected $SHA)" >&2; exit 1
fi

echo "ok: $REPO production -> $VERSION ($SHA), verified"
