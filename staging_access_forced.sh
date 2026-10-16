#!/usr/bin/env bash
# Restricted forced-command for the "staging access" SSH key (mirrors promote_forced.sh).
#
# Install on the STAGING server (62.238.17.178). The matching public key goes in
# /root/.ssh/authorized_keys pinned to this command (one line):
#
#   command="/root/staging_access_forced.sh",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty ssh-ed25519 AAAA... staging-access
#
# Invoked by "E2E (staging)" in fantasy-web, whose GitHub runner has a different IP on every run:
#   ssh root@62.238.17.178 "allow"   ->  let the CALLER's own IPv4 through :443 for a while
#   ssh root@62.238.17.178 "revoke"  ->  take the caller's own IPv4 back out
#
# Neither takes an argument: the IP is the one this SSH connection came from ($SSH_CLIENT),
# so the key can only ever let its own caller in, never name someone else. An allowed IP carries
# an iptables time match and stops matching ALLOW_TTL_MINUTES after it was added, so a runner
# that dies before its revoke step leaves a dead rule rather than an open door; every call sweeps
# the dead ones.
#
# It can ONLY let its own caller through the pre-launch HTTPS IP gate — nothing else.
set -euo pipefail

ALLOW_TTL_MINUTES=90
TAG=e2e-runner
PUBIF="$(ip -o route get 1.1.1.1 2>/dev/null | sed -n 's/.* dev \([^ ]*\) .*/\1/p')"
PUBIF="${PUBIF:-eth0}"

caller_ipv4() {
  local ip="${SSH_CLIENT%% *}" o
  if [[ ! "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
    echo "refused: caller address '$ip' is not IPv4" >&2
    return 1
  fi
  for o in ${ip//./ }; do
    if ((10#$o > 255)); then
      echo "refused: caller address '$ip' is not IPv4" >&2
      return 1
    fi
  done
  echo "$ip"
}

# Deletes this script's rules: every one for a source when given an IP, otherwise only those whose
# time match has run out. `iptables -S` prints a rule as the arguments that created it, so turning
# -A into -D gives its delete; nothing in these rules contains a space, so word splitting is safe.
delete_rules() {
  local only_ip="${1:-}" now line stop args
  now="$(date -u +%Y-%m-%dT%H:%M:%S)"
  iptables -S DOCKER-USER | { grep -- "--comment $TAG" || true; } | while read -r line; do
    if [ -n "$only_ip" ]; then
      [[ "$line" == *"-s $only_ip/32 "* ]] || continue
    else
      stop="$(sed -n 's/.*--datestop \([^ ]*\).*/\1/p' <<<"$line")"
      [[ -n "$stop" && "$stop" < "$now" ]] || continue
    fi
    read -ra args <<<"${line/#-A /-D }"
    iptables "${args[@]}"
  done
}

delete_rules

MODE="${SSH_ORIGINAL_COMMAND:-}"
case "$MODE" in
  allow)
    IP="$(caller_ipv4)"
    delete_rules "$IP"
    STOP="$(date -u -d "+$ALLOW_TTL_MINUTES minutes" +%Y-%m-%dT%H:%M:%S)"
    # Inserted at the top, above ip-allowlist.sh's DROP.
    iptables -I DOCKER-USER -i "$PUBIF" -p tcp -m multiport --dports 443 -s "$IP" \
      -m time --datestop "$STOP" -m comment --comment "$TAG" -j RETURN
    echo "ok: $IP may reach :443 until $STOP UTC"
    ;;
  revoke)
    IP="$(caller_ipv4)"
    delete_rules "$IP"
    echo "ok: $IP no longer allowed through :443"
    ;;
  *)
    echo "refused: expected 'allow' or 'revoke', got '$MODE'" >&2
    exit 1
    ;;
esac
