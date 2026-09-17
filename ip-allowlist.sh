#!/usr/bin/env bash
# Dev-phase gate: only ALLOW_IP may reach the app over HTTPS (443) on the public interface, over TCP
# and over UDP. Traefik serves HTTP/3 on UDP 443 and Docker publishes it, so a TCP-only gate is
# open to any client that speaks HTTP/3; today only Hetzner's Cloud Firewall (TCP 22/80/443) stops
# that, and this gate must not depend on it.
# Port 80 stays open (http->https redirect + Let's Encrypt HTTP-01 renewal). SSH (22) untouched.
# Applied to Docker's DOCKER-USER chain (covers Coolify/Traefik published ports).
# Revert (go public): FLUSH=1 /root/ip-allowlist.sh ; systemctl disable ip-allowlist.service
#
# Change the owner IP by changing the ALLOW_IP default below (in the monorepo, then reinstall) and
# running the script. `ALLOW_IP=<new> /root/ip-allowlist.sh` works for that one run only: the next
# boot or `lock` applies the default again.
#
# Install on the STAGING server (62.238.17.178) as /root/ip-allowlist.sh; ip-allowlist.service
# runs it on boot and staging_access_forced.sh runs it on `lock`. Services that must reach staging
# from outside while it is locked (Stripe's webhooks) are listed one IPv4 per line in EXTRA_FILE,
# installed from ip-allowlist.staging.extra in the monorepo root.
set -euo pipefail
ALLOW_IP="${ALLOW_IP:-80.216.235.61}"
PORTS="${PORTS:-443}"
EXTRA_FILE="${EXTRA_FILE:-/root/ip-allowlist.extra}"
TAG=ip-allowlist
PROTOS=(tcp udp)
PUBIF="$(ip -o route get 1.1.1.1 2>/dev/null | sed -n 's/.* dev \([^ ]*\) .*/\1/p')"; PUBIF="${PUBIF:-eth0}"
HAVE_V6=0
if command -v ip6tables >/dev/null && ip6tables -L DOCKER-USER >/dev/null 2>&1; then HAVE_V6=1; fi

is_ipv4() { [[ "$1" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; }

# Everything is read and checked before any rule is touched, so bad input leaves the gate as it was
# rather than half torn down (which would leave staging open).
if ! is_ipv4 "$ALLOW_IP"; then
  echo "refused: ALLOW_IP '$ALLOW_IP' is not an IPv4 address" >&2
  exit 1
fi
EXTRA=()
if [ -f "$EXTRA_FILE" ]; then
  while read -r ip _; do
    [[ -z "$ip" || "$ip" == \#* ]] && continue
    if ! is_ipv4 "$ip"; then
      echo "refused: '$ip' in $EXTRA_FILE is not an IPv4 address" >&2
      exit 1
    fi
    EXTRA+=("$ip")
  done <"$EXTRA_FILE"
fi

# Removes this gate's rules by what they are, never by the values this run was given: a rule for an
# owner IP that has since changed would otherwise stay behind and keep that address let in.
# Tagged rules are this version's. Untagged 443 / 80,443 RETURN and DROP rules on the public
# interface were written by versions before the tag (`allowlist-extra` is the extra rules' old tag).
# Rules with any other comment belong to someone else, e.g. staging_access_forced.sh's e2e-runner.
# `-S` prints a rule as the arguments that created it, so turning -A into -D gives its delete;
# nothing in these rules contains a space, so word splitting is safe.
remove_gate_rules() {
  local cmd="$1" line args
  "$cmd" -S DOCKER-USER | while read -r line; do
    if [[ "$line" == *"--comment $TAG "* || "$line" == *"--comment allowlist-extra "* ]]; then
      :
    elif [[ "$line" != *"--comment "* && "$line" == *"-i $PUBIF "* \
      && "$line" =~ -m\ multiport\ --dports\ (443|80,443)\ -j\ (RETURN|DROP)$ ]]; then
      :
    else
      continue
    fi
    read -ra args <<<"${line/#-A /-D }"
    "$cmd" "${args[@]}"
  done
}

remove_gate_rules iptables
if [ "$HAVE_V6" = 1 ]; then remove_gate_rules ip6tables; fi
if [ "${FLUSH:-0}" = "1" ]; then echo "flushed allowlist on $PUBIF"; exit 0; fi
for PROTO in "${PROTOS[@]}"; do
  RULE=(-i "$PUBIF" -p "$PROTO" -m multiport --dports "$PORTS")
  iptables -I DOCKER-USER "${RULE[@]}" -m comment --comment "$TAG" -j DROP
  for ip in "${EXTRA[@]}"; do
    iptables -I DOCKER-USER -s "$ip" "${RULE[@]}" -m comment --comment "$TAG" -j RETURN
  done
  iptables -I DOCKER-USER -s "$ALLOW_IP" "${RULE[@]}" -m comment --comment "$TAG" -j RETURN
  if [ "$HAVE_V6" = 1 ]; then
    ip6tables -I DOCKER-USER "${RULE[@]}" -m comment --comment "$TAG" -j DROP
  fi
done
echo "allowlist on $PUBIF: only $ALLOW_IP and ${#EXTRA[@]} listed service IPs reach :$PORTS (v4, tcp+udp); :80 open (ACME + redirect); v6 :$PORTS dropped"
