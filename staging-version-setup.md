# Staging version auto-injection — one-time setup

Goal: on every merge, each repo's `tag-on-merge` workflow tells the **prod server** (which runs
the Coolify control plane + holds the API token) to set `APP_VERSION=<new tag>` on that repo's
**staging** app and redeploy it — so the staging version panel shows the real SemVer instead of
`dev`. It mirrors your existing `promote-to-prod` restricted-SSH pattern, so nothing has to call
the IP-locked Coolify API from GitHub Actions.

The app code already reads `APP_VERSION` (services at runtime, web as a build-arg). The workflow
step is added in each repo (see the PRs). The rest is this one-time server + secrets setup.

## 1. Restricted SSH key (you generate — don't share the private half with anyone)

```bash
ssh-keygen -t ed25519 -N '' -f ./staging-version-key -C 'staging-version'
```

- **Private half** (`staging-version-key`): add as the secret `STAGING_VERSION_SSH_KEY` in all
  five repos:
  ```bash
  for r in fantasy-web fantasy-bff fantasy-db-service fantasy-espn-service fantasy-projection-service fantasy-yahoo-service; do
    gh secret set STAGING_VERSION_SSH_KEY --repo pgaberra/$r < ./staging-version-key
  done
  ```
- **Public half** (`staging-version-key.pub`): on the **prod server** add to `/root/.ssh/authorized_keys`,
  pinned to the forced command (one line):
  ```
  command="/root/set_staging_version_forced.sh",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty ssh-ed25519 AAAA...staging-version
  ```

## 2. Install the forced-command script on the prod server

Copy `set_staging_version_forced.sh` to `/root/set_staging_version_forced.sh` and `chmod 700` it.

## 3. Map each repo to its staging app UUID

On the prod server, create `/root/staging_app_uuids.txt` (get the UUIDs from Coolify → the
`staging` environment apps):

```
fantasy-web=<staging-web-uuid>
fantasy-bff=<staging-bff-uuid>
fantasy-db-service=<staging-db-uuid>
fantasy-espn-service=<staging-espn-uuid>
fantasy-projection-service=<staging-projection-uuid>
fantasy-yahoo-service=<staging-yahoo-uuid>
```

## 4. Pre-create the `APP_VERSION` env on each staging app (Coolify UI)

Coolify's env-`PATCH` API can't set the build-time flag, so create the variable once with the
correct flag (the script then just updates its value):

- **fantasy-web** → `APP_VERSION` as a **Build-time** variable (it's baked into the static bundle).
- **fantasy-bff / db / nhl / yahoo** → `APP_VERSION` as a **Runtime** variable.

(Leave the value blank or `dev`; the first merge after setup overwrites it.)

## Verify

Merge any PR to a repo's `master` → the `tag-on-merge` run shows `ok: <repo> staging -> vX.Y.Z`
→ staging redeploys → the version panel shows the real tag for that service. Until setup is done
the workflow step is a safe no-op (it logs a notice and exits).

> Note: staging also auto-deploys on the push itself, so each merge briefly builds twice (once
> from the push with the previous value, once from this step with the new tag). Harmless on staging.
