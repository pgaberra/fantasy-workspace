# Staging access toggle — one-time setup

A GitHub Actions workflow (`fantasy-web` → Actions → **"Staging access (open / lock)"** → Run
workflow) that opens the staging server's HTTPS firewall so you can reach
`https://staging.slapstat.com` from any device (e.g. a phone on mobile data), or re-locks it.

It runs over a **restricted SSH key** whose only allowed action is
`/root/staging_access_forced.sh` on the **staging** server — the same forced-command pattern as
`promote-to-prod`. The firewall change happens server-side; you just press "Run".

> Why a toggle and not "whitelist my IP": a phone on mobile data has a **dynamic** (often CGNAT)
> IP, and the workflow runs on a GitHub runner that can't see your phone's IP anyway — so the
> only thing that reliably works for mobile is open ⇄ lock. While "open", staging is public
> (no prod data; prod is unaffected) — keep the window short, or use Cloudflare Access for a
> permanent identity gate.

## 1. Restricted SSH key (you generate)

```bash
ssh-keygen -t ed25519 -N '' -f ./staging-access-key -C 'staging-access'
```

- **Private half** (`staging-access-key`) → secret `STAGING_ACCESS_SSH_KEY` in `fantasy-web`:
  ```bash
  gh secret set STAGING_ACCESS_SSH_KEY --repo pgaberra/fantasy-web < ./staging-access-key
  ```
- **Public half** (`staging-access-key.pub`) → on the **staging server** (`62.238.17.178`) add
  to `/root/.ssh/authorized_keys`, pinned to the forced command (one line):
  ```
  command="/root/staging_access_forced.sh",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty ssh-ed25519 AAAA...staging-access
  ```

## 2. Install the forced-command script on the staging server

Copy `staging_access_forced.sh` to `/root/staging_access_forced.sh` on `62.238.17.178` and
`chmod 700` it. Confirm the `lock` branch matches how your `ip-allowlist.sh` re-locks (see the
comment in the script).

## Use it

`fantasy-web` → **Actions** → **"Staging access (open / lock)"** → **Run workflow** → pick
`open` (reach staging from anywhere) or `lock` (restore the owner-IP gate). Works from the
GitHub mobile app / browser too.

> The workflow pins the staging server's SSH host key, so no blind trust-on-first-use.
