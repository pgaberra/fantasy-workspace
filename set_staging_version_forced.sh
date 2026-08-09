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
# and only ever: sets APP_VERSION on the repo's STAGING Coolify app + redeploys it.
#
# Requires (one-time):
#   /root/.coolify_token            — Coolify API token (already present).
#   /root/staging_app_uuids.txt     — "repo=uuid" per line, e.g. fantasy-web=abc123.
#   APP_VERSION env pre-created on each staging app in Coolify, with the right flag:
#     fantasy-web  -> Build-time variable (it is baked into the static bundle)
#     the 4 Java services -> Runtime variable (read at startup via ${APP_VERSION:dev})
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

# Update the value of the (pre-created) APP_VERSION env on the staging app.
if ! curl -fsS -X PATCH "$BASE/applications/$UUID/envs" \
      -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
      -d "{\"key\":\"APP_VERSION\",\"value\":\"$VERSION\"}" >/dev/null; then
  echo "failed: could not set APP_VERSION on $REPO ($UUID) — is the env pre-created on the app?" >&2
  exit 1
fi

# Redeploy so the new value takes effect (rebuild for web's build-arg; restart for the services).
curl -fsS "$BASE/deploy?uuid=$UUID" -H "Authorization: Bearer $TOKEN" >/dev/null

echo "ok: $REPO staging -> $VERSION"
