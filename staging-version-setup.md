# Staging version auto-injection — setup & how to add a service

Goal: on every merge, each repo's `tag-on-merge` workflow tells the **prod server** (which runs
the Coolify control plane + holds the API token) to set `APP_VERSION=<new tag>` on that repo's
**staging** app and redeploy it — so the staging version panel shows the real SemVer instead of
`dev`. It mirrors the `promote-to-prod` restricted-SSH pattern, so nothing has to call the
IP-locked Coolify API from GitHub Actions.

The app code already reads `APP_VERSION` (services at runtime, web as a build-arg).

## 1. Restricted SSH keys — one pair per service

**Each service gets its own key pair.** The original setup used a single shared
`staging-version` key rolled out across repos; that is no longer the pattern, and the private
half of the shared key is not on any machine we control. Do **not** go looking for it when
wiring a new service — generate a fresh pair, which is what `fantasy-espn-service` and
`fantasy-projection-service` both did.

```bash
ssh-keygen -t ed25519 -N '' -f ./<service>-staging-version -C 'staging-version-<service>'
```

- **Private half** (no extension) → the repo secret `STAGING_VERSION_SSH_KEY`:
  ```bash
  gh secret set STAGING_VERSION_SSH_KEY --repo pgaberra/<service> < ./<service>-staging-version
  ```
  Then **store it in the password manager and delete the local file.** GitHub secrets are
  write-only — a lost private half means generating a new pair, not recovering the old one.
- **Public half** (`.pub`) → on the **prod server**, appended to `/root/.ssh/authorized_keys`
  pinned to the forced command (one line):
  ```
  command="/root/set_staging_version_forced.sh",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty ssh-ed25519 AAAA...staging-version-<service>
  ```
  Append with a `grep -qxF … || echo … >>` guard — never rewrite the file. It also holds the
  `promote_forced.sh` keys and the owner's full-root keys.

The same applies to `PROD_PROMOTE_SSH_KEY` / `promote_forced.sh` for prod promotion.

## 2. Install the forced-command script on the prod server

Copy `set_staging_version_forced.sh` to `/root/set_staging_version_forced.sh` and `chmod 700` it.

## 3. Map the repo to its staging app UUID

On the prod server, `/root/staging_app_uuids.txt` holds one `repo=uuid` line per service (and
`/root/prod_app_uuids.txt` the prod equivalents). Get UUIDs from Coolify → the `staging`
environment apps. `fantasy-nhl-service` was retired in 2026 and is absent from both.

## 4. Add the repo to the script's whitelist

`set_staging_version_forced.sh` refuses any repo not in its `case` list — a missing entry is
answered with `refused: unknown repo`, and it is the easiest thing to forget. **Keep the list
in sync with `/root/promote_forced.sh`**, and keep the copy in this repo in sync with the
server.

## 5. Pre-create the `APP_VERSION` env on the Coolify apps

Coolify's env-`PATCH` API can't set the build-time flag, and the script only ever **updates an
existing** variable — if it is missing the run fails with *"is the env pre-created on the app?"*.
Create it once, on **both** the staging and prod app:

- **fantasy-web** → **Build-time** variable (it's baked into the static bundle).
- **every other service** → **Runtime** variable. That covers the Java services and the Python
  `fantasy-projection-service`.

(Value can be `dev`; the first merge after setup overwrites it.)

Also create `SENTRY_RELEASE` as a **Runtime** variable on each **staging backend** app (every
service except `fantasy-web`, whose `@sentry/browser` takes its release from the `APP_VERSION`
baked into the bundle). The script stamps it with the same tag, so staging events carry the
release that is actually running (fantasy-workspace#61). Without it the stamp step still
deploys, but prints a warning and the app's events carry no release. Production apps already
have it; `promote_forced.sh` stamps it at promotion and fails without it.

## 6. Turn Coolify's auto-deploy off on the staging app

The stamped redeploy from `tag-on-merge` is **staging's only intended deploy path**. Coolify's
own auto-deploy (the push webhook) must be **off** on every staging app, as it is in production.

With it on, each merge starts two deploys of the same commit: the webhook build, carrying the
previous `APP_VERSION`, and the stamped one seconds later. Whichever finishes last is what
staging runs and what `/api/v1/versions` and the staging banner report, so staging can run the
new code under the old version number. Promotion checks read `/versions`, so this is not
harmless.

The script looks for this: if the app has a webhook deployment from the last 30 minutes, it
prints a `::warning::` annotation on the `tag-on-merge` run and still deploys. It warns rather
than refusing like `promote_forced.sh` does, because a refusal would skip the stamped deploy and
leave the unstamped webhook build as the only one.

## Checklist for a new service

All five must be true, or the merge fails at the stamp step:

1. Repo secret `STAGING_VERSION_SSH_KEY` set (and `PROD_PROMOTE_SSH_KEY` for promotion)
2. Public half pinned to the forced command in prod's `authorized_keys`
3. Repo present in `/root/staging_app_uuids.txt`
4. Repo present in the whitelist inside `set_staging_version_forced.sh`
5. `APP_VERSION` pre-created as a Runtime (or Build-time, for web) variable in Coolify

These two don't fail the merge, but the run warns until they are true:

6. `SENTRY_RELEASE` pre-created as a Runtime variable (not for web)
7. Coolify auto-deploy off on the staging app

## Verify

Merge any PR to the repo's `master` → the `tag-on-merge` run shows `ok: <repo> staging -> vX.Y.Z`
with no warning annotations → staging redeploys → the version panel shows the real tag.

The stamp step **fails the job loudly** if any of items 1–5 is missing — it is deliberately not a
no-op, because a silent skip once left staging undeployed with nothing but a notice to show for
it.
