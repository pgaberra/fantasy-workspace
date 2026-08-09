#!/usr/bin/env bash
# Restricted forced-command for the "staging access" SSH key (mirrors promote_forced.sh).
#
# Install on the STAGING server (62.238.17.178). The matching public key goes in
# /root/.ssh/authorized_keys pinned to this command (one line):
#
#   command="/root/staging_access_forced.sh",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty ssh-ed25519 AAAA... staging-access
#
# Invoked by the "Staging access (open / lock)" GitHub workflow as:
#   ssh root@62.238.17.178 "open"   ->  expose :443 to everyone (any device / mobile data)
#   ssh root@62.238.17.178 "lock"   ->  restore the owner-IP lockdown
# It can ONLY toggle the pre-launch HTTPS IP gate (/root/ip-allowlist.sh) — nothing else.
set -euo pipefail

MODE="${SSH_ORIGINAL_COMMAND:-}"
case "$MODE" in
  open)
    FLUSH=1 /root/ip-allowlist.sh
    echo "ok: staging access OPEN (HTTPS reachable from any IP)"
    ;;
  lock)
    # Re-applies the stored owner-IP allow-list. Confirm this matches how your
    # ip-allowlist.sh re-locks (the same invocation ip-allowlist.service uses on boot).
    # If your script needs the IP passed explicitly, change this to:
    #   ALLOW_IP=<your-ip> /root/ip-allowlist.sh
    /root/ip-allowlist.sh
    echo "ok: staging access LOCKED (HTTPS restricted to the owner IP)"
    ;;
  *)
    echo "refused: expected 'open' or 'lock', got '$MODE'" >&2
    exit 1
    ;;
esac
