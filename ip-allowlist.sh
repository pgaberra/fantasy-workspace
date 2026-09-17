#!/usr/bin/env bash
# Dev-phase gate: only ALLOW_IP may reach the app over HTTPS (443) on the public interface, over TCP
# and over UDP. Traefik serves HTTP/3 on UDP 443 and Docker publishes it, so a TCP-only gate is
# open to any client that speaks HTTP/3; today only Hetzner's Cloud Firewall (TCP 22/80/443) stops
# that, and this gate must not depend on it.
# Port 80 stays open (http->https redirect + Let's Encrypt HTTP-01 renewal). SSH (22) untouched.
# Applied to Docker's DOCKER-USER chain (covers Coolify/Traefik published ports).
# Revert (go public): FLUSH=1 /root/ip-allowlist.sh ; systemctl disable ip-allowlist.service
# Change IP: ALLOW_IP=<new> /root/ip-allowlist.sh
#
# Install on the STAGING server (62.238.17.178) as /root/ip-allowlist.sh; ip-allowlist.service
# runs it on boot and staging_access_forced.sh runs it on `lock`. Services that must reach staging
# from outside while it is locked (Stripe's webhooks) are listed one IPv4 per line in EXTRA_FILE,
# installed from ip-allowlist.staging.extra in the monorepo root.
set -euo pipefail
ALLOW_IP="${ALLOW_IP:-80.216.235.61}"
PORTS="${PORTS:-443}"
EXTRA_FILE="${EXTRA_FILE:-/root/ip-allowlist.extra}"
EXTRA_TAG=allowlist-extra
PROTOS=(tcp udp)
PUBIF="$(ip -o route get 1.1.1.1 2>/dev/null | sed -n 's/.* dev \([^ ]*\) .*/\1/p')"; PUBIF="${PUBIF:-eth0}"
# Read and checked in full before any rule is touched, so a bad line leaves the gate as it was
# rather than half torn down (which would leave staging open).
EXTRA=()
if [ -f "$EXTRA_FILE" ]; then
  while read -r ip _; do
    [[ -z "$ip" || "$ip" == \#* ]] && continue
    if [[ ! "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
      echo "refused: '$ip' in $EXTRA_FILE is not an IPv4 address" >&2
      exit 1
    fi
    EXTRA+=("$ip")
  done <"$EXTRA_FILE"
fi
for P in "80,443" "$PORTS"; do
  for PROTO in "${PROTOS[@]}"; do
    iptables -D DOCKER-USER -i "$PUBIF" -p "$PROTO" -m multiport --dports "$P" -s "$ALLOW_IP" -j RETURN 2>/dev/null || true
    iptables -D DOCKER-USER -i "$PUBIF" -p "$PROTO" -m multiport --dports "$P" -j DROP 2>/dev/null || true
    if command -v ip6tables >/dev/null && ip6tables -L DOCKER-USER >/dev/null 2>&1; then
      ip6tables -D DOCKER-USER -i "$PUBIF" -p "$PROTO" -m multiport --dports "$P" -j DROP 2>/dev/null || true
    fi
  done
done
# The extra rules are tagged, so they are removed by what they are rather than by re-reading a file
# that may have changed since they were added. `iptables -S` prints a rule as the arguments that
# created it, so turning -A into -D gives its delete.
iptables -S DOCKER-USER | { grep -- "--comment $EXTRA_TAG" || true; } | while read -r line; do
  read -ra args <<<"${line/#-A /-D }"
  iptables "${args[@]}"
done
if [ "${FLUSH:-0}" = "1" ]; then echo "flushed allowlist on $PUBIF"; exit 0; fi
for PROTO in "${PROTOS[@]}"; do
  iptables -I DOCKER-USER -i "$PUBIF" -p "$PROTO" -m multiport --dports "$PORTS" -j DROP
  for ip in "${EXTRA[@]}"; do
    iptables -I DOCKER-USER -i "$PUBIF" -p "$PROTO" -m multiport --dports "$PORTS" -s "$ip" -m comment --comment "$EXTRA_TAG" -j RETURN
  done
  iptables -I DOCKER-USER -i "$PUBIF" -p "$PROTO" -m multiport --dports "$PORTS" -s "$ALLOW_IP" -j RETURN
  if command -v ip6tables >/dev/null && ip6tables -L DOCKER-USER >/dev/null 2>&1; then
    ip6tables -I DOCKER-USER -i "$PUBIF" -p "$PROTO" -m multiport --dports "$PORTS" -j DROP
  fi
done
echo "allowlist on $PUBIF: only $ALLOW_IP and ${#EXTRA[@]} listed service IPs reach :$PORTS (v4, tcp+udp); :80 open (ACME + redirect); v6 :$PORTS dropped"
