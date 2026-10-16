# Staging access for E2E — one-time setup

Staging (`https://staging.slapstat.com`) is locked to the owner's IP by `ip-allowlist.sh`.
`E2E (staging)` in `fantasy-web` gets through on its own: it calls `allow` before the tests and
`revoke` after them, over a **restricted SSH key** whose only allowed action is
`/root/staging_access_forced.sh` on the **staging** server — the same forced-command pattern as
`promote-to-prod`.

## 1. Restricted SSH key (you generate)

```bash
ssh-keygen -t ed25519 -N '' -f ./staging-access-key -C 'staging-access'
```

- **Private half** (`staging-access-key`) → secret `STAGING_ACCESS_SSH_KEY` in `fantasy-web`:
  ```bash
  gh secret set STAGING_ACCESS_SSH_KEY --repo slapstat/fantasy-web < ./staging-access-key
  ```
- **Public half** (`staging-access-key.pub`) → on the **staging server** (`62.238.17.178`) add
  to `/root/.ssh/authorized_keys`, pinned to the forced command (one line):
  ```
  command="/root/staging_access_forced.sh",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty ssh-ed25519 AAAA...staging-access
  ```

## 2. Install the forced-command script on the staging server

Copy `staging_access_forced.sh` to `/root/staging_access_forced.sh` on `62.238.17.178` and
`chmod 700` it.

## How the E2E runner gets through

The server lets in only the IP the SSH connection came from, over HTTPS, and the rule carries an
iptables time match that stops it matching after 90 minutes, so a runner that dies before
`revoke` does not leave a door open; every call to the script sweeps expired rules. Re-running
`/root/ip-allowlist.sh` on the box while a suite is running puts its DROP back above the runner's
rule, shuts that runner out and reddens the run.

The workflow pins the staging server's SSH host key, so no blind trust-on-first-use.

Anything else that has to reach staging from outside is shut out, unless its addresses are in
`/root/ip-allowlist.extra`. No external uptime check watches staging for that reason; Sentry's,
which did, is disabled, and UptimeRobot watches production.

## Services let through the lock

`ip-allowlist.sh` (versioned here, installed as `/root/ip-allowlist.sh`) also lets through every
IPv4 in `/root/ip-allowlist.extra`, installed from `ip-allowlist.staging.extra`. Today that is
Stripe's webhook senders, so test-mode webhooks reach `api.staging.slapstat.com`. The rules are
re-applied on boot. After changing the file, run `/root/ip-allowlist.sh` on the box. A file with a
line that is not an IPv4 address is refused before any rule is touched.

## Opening staging by hand

There is no workflow for it any more (removed in slapstat/fantasy-web#1217). On the box,
`FLUSH=1 /root/ip-allowlist.sh` opens HTTPS to everyone and `/root/ip-allowlist.sh` locks it
again. Locked is the default; keep any open window short.
