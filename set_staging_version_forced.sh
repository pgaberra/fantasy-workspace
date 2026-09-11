#!/usr/bin/env bash
# Restricted forced-command for the "staging version" SSH key (mirrors promote_forced.sh).
#
# Install on the PROD server (157.180.126.72 — it runs the Coolify control plane that
# manages BOTH environments, and holds /root/.coolify_token). The matching public key goes
# in /root/.ssh/authorized_keys pinned to this command, e.g.:
#
#   command="/root/set_staging_version_forced.sh",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty ssh-ed25519 AAAA... staging-version
#
# It is invoked by each repo's tag-on-merge workflow as:  ssh root@prod "<repo> <vX.Y.Z>"
# and only ever: sets APP_VERSION (and SENTRY_RELEASE, where the app has one) on the repo's
# STAGING Coolify app + redeploys it. That redeploy is staging's only intended deploy path:
# Coolify's own auto-deploy must be off on every staging app (staging-version-setup.md).
#
# Requires (one-time):
#   /root/.coolify_token            — Coolify API token (already present).
#   /root/staging_app_uuids.txt     — "repo=uuid" per line, e.g. fantasy-web=abc123.
#   jq
#   APP_VERSION env pre-created on each staging app in Coolify, with the right flag:
#     fantasy-web  -> Build-time variable (it is baked into the static bundle)
#     every other service -> Runtime variable (read at startup via ${APP_VERSION:dev});
#       that covers the Java services and the Python fantasy-projection-service.
#   SENTRY_RELEASE env pre-created as a Runtime variable on each staging app except
#     fantasy-web (the web takes its release from APP_VERSION). Missing, it is skipped with a
#     warning rather than failing the merge.
#
# Keep the repo list below in sync with /root/promote_forced.sh. fantasy-nhl-service was
# retired in 2026 (its Coolify app no longer exists) and is deliberately absent.
set -euo pipefail

read -r REPO VERSION _ <<< "${SSH_ORIGINAL_COMMAND:-}"

case "$REPO" in
  fantasy-web|fantasy-bff|fantasy-db-service|fantasy-espn-service|fantasy-projection-service|fantasy-yahoo-service) ;;
  *) echo "refused: unknown repo '$REPO'" >&2; exit 1 ;;
esac
if [[ ! "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "refused: bad version '$VERSION'" >&2; exit 1
fi

UUID="$(grep -E "^${REPO}=" /root/staging_app_uuids.txt 2>/dev/null | head -1 | cut -d= -f2 || true)"
if [ -z "$UUID" ]; then echo "refused: no staging UUID mapped for '$REPO'" >&2; exit 1; fi

# tr -d, not cat: a token pasted from Windows carries a CR, which makes the Authorization
# header end in \r and nginx answer 400 before Coolify ever sees the request.
TOKEN="$(tr -d '\r\n' < /root/.coolify_token)"
BASE="https://coolify.slapstat.com/api/v1"
api() { curl -fsS -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" "$@"; }
set_env() {
  api -X PATCH "$BASE/applications/$UUID/envs" \
    -d "$(jq -nc --arg k "$1" --arg v "$2" '{key:$k, value:$v}')" >/dev/null
}

# Warn when Coolify also deploys this app on its own. With auto-deploy on, the merge's push
# starts a webhook build carrying the previous APP_VERSION seconds before the stamped one
# below, and whichever finishes last is what staging runs and what /versions reports.
# promote_forced.sh refuses in the same situation; this one only warns, because refusing
# here would skip the stamped deploy and leave the unstamped webhook build as the only one.
# The application API exposes no auto-deploy flag, so look for its footprint: a webhook
# deployment in the last 30 minutes, i.e. one started by this merge's push. (Older webhook
# deployments are history from before auto-deploy was switched off and prove nothing now.)
# The `::warning::` prefix makes the line an annotation on the tag-on-merge run.
if DEPLOYMENTS="$(api "$BASE/deployments/applications/$UUID")"; then
  RECENT_WEBHOOK="$(jq -r '[.deployments[]? | select(.is_webhook == true)
      | select((.created_at[0:19] + "Z" | fromdateiso8601) > (now - 1800))]
      | length' <<< "$DEPLOYMENTS" 2>/dev/null || echo "?")"
else
  RECENT_WEBHOOK="?"
fi
if [ "$RECENT_WEBHOOK" = "?" ]; then
  echo "::warning::could not read $REPO's staging deployments, so whether Coolify auto-deploy is off went unchecked"
elif [ "$RECENT_WEBHOOK" != "0" ]; then
  echo "::warning::$REPO staging also deployed from a push webhook in the last 30 minutes, so Coolify auto-deploy is on. Staging may end up running this commit under the previous APP_VERSION. Turn auto-deploy off on the staging app (staging-version-setup.md)."
fi

# Update the value of the (pre-created) APP_VERSION env on the staging app.
if ! set_env APP_VERSION "$VERSION"; then
  echo "failed: could not set APP_VERSION on $REPO ($UUID) — is the env pre-created on the app?" >&2
  exit 1
fi

# Stamp SENTRY_RELEASE too, so staging events carry the release that is actually running
# (fantasy-workspace#61). fantasy-web is skipped: @sentry/browser takes its release from the
# APP_VERSION baked into the bundle and reads no SENTRY_RELEASE. The PATCH only updates an
# existing variable, so check first. A missing or failing SENTRY_RELEASE warns and carries on
# instead of failing: APP_VERSION is already stamped, and stopping before the deploy would
# leave staging on the old build over a reporting tag. Creating the variable here was rejected
# (see DECISIONS.md): it would widen what six CI keys can do from updating two values to adding
# variables, with flags this script would have to guess.
if [ "$REPO" != "fantasy-web" ]; then
  if ! ENVS="$(api "$BASE/applications/$UUID/envs")"; then
    echo "::warning::could not read $REPO's staging env, so SENTRY_RELEASE was not stamped"
  elif ! jq -e '[.[]? | select(.key == "SENTRY_RELEASE" and .is_preview == false)] | length > 0' \
         <<< "$ENVS" >/dev/null; then
    echo "::warning::$REPO's staging app has no SENTRY_RELEASE variable, so its Sentry events carry no release. Create it once as a Runtime variable (staging-version-setup.md)."
  elif ! set_env SENTRY_RELEASE "$VERSION"; then
    echo "::warning::could not set SENTRY_RELEASE on $REPO ($UUID); staging events keep the previous release"
  fi
fi

# Redeploy so the new value takes effect (rebuild for web's build-arg; restart for the services).
# POST, not GET: Coolify answers a GET here with 405, which stamped the version and then left
# staging running the previous build. promote_forced.sh has always used POST — this is the same
# endpoint, so the two now call it the same way.
DEPLOY_RESPONSE="$(api -X POST "$BASE/deploy?uuid=$UUID&force=false")"
DEPLOYMENT_UUID="$(jq -r '.deployments[0].deployment_uuid // ""' <<< "$DEPLOY_RESPONSE")"
if [ -z "$DEPLOYMENT_UUID" ]; then
  # A 2xx that queues nothing would leave the stamped version unbuilt without saying so, which
  # is the same silence in a different shape.
  echo "failed: deploy of $REPO returned no deployment uuid — version stamped but not built" >&2
  exit 1
fi

echo "ok: $REPO staging -> $VERSION (deployment $DEPLOYMENT_UUID)"
