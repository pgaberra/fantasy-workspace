# Troubleshooting — "I got a Sentry error, now what?"

The runbook for debugging a backend error, end to end. Backend services (bff, db-service,
espn-service, yahoo-service) forward every **ERROR-level log** to **Sentry**, which emails you
and groups the error into an issue. (Architecture & deploy model: see `INFRASTRUCTURE.md`.)

> Quick links: **Sentry** project `slapstat-backend` · **Coolify** `https://coolify.slapstat.com`
> · prod API `https://api.slapstat.com` · staging API `https://api.staging.slapstat.com`.

---

## 1. The email is just a ping — open the Sentry issue

Click through to the **issue in Sentry**. That's the main surface. It tells you:

| In the issue | What it tells you |
|---|---|
| **Environment** tag | `staging` or `production` — which env the error came from. |
| **Release** | the version, e.g. `v0.2.1` (prod only; staging shows none — it's always latest). |
| **Culprit / stack trace** | the exact file + line, and the Java package → **which service**: `com.fantasy.db` = db-service, `.espn` = espn-service, `.bff` = bff, `.yahoo` = yahoo-service. A Python traceback is projection-service, which has no Sentry SDK — it will not appear here at all, so look in its container logs. |
| **Breadcrumbs** | the INFO logs *just before* the error — often enough to see what led there. |
| **Events / frequency** | first seen, last seen, count. Grouped, so one recurring error = one issue. |

---

## 2. Triage — is it real, and is it urgent?

The message + stack trace usually tells you which of these it is:

- **Transient blip** — e.g. a `ResourceAccessException` against a service that was restarting.
  One-off, self-healed. Since health checks were enabled (August 2026) a deploy should no
  longer cause these, so one that lines up with a deploy is worth a second look rather than a
  shrug: compare the timestamp against the container's start in that app's log.
- **Downstream outage** — `Downstream service call failed` against e.g. `db-service:8086`.
  A backend service was unreachable. Check that service's health/logs.
- **Code bug** — an unexpected exception (NullPointer, parsing, etc.) in a controller/service.
  The stack trace points to the line. → fix in code.
- **Config/env** — auth/key mismatch, missing env var. Check the app's env in Coolify.

The **Release** tag answers "did this start in a specific version?" — compare against earlier
versions in Sentry's **Releases** view.

---

## 3. Need more than the stack trace → the live logs

Sentry gives the exception + breadcrumbs. For the full log stream around that moment:

- **Coolify (easiest):** `https://coolify.slapstat.com` → open the service (e.g. `prod-bff`) →
  **Logs** tab → scroll to the timestamp from the Sentry event.
- **SSH (full control):** `ssh root@157.180.126.72` (prod) or `root@62.238.17.178` (staging),
  then `docker logs --since 10m <container>` (find it with `docker ps`).

---

## 4. Staging is your safety net

- A **staging** error means you caught it **before** prod. Staging auto-deploys the latest
  `master`, so it's the early-warning system — fix before promoting.
- A **prod** error affects the pinned prod version → fix, verify on staging, then promote.

---

## 5. Fix → deploy

The normal loop (the low-ops path: hand the Sentry link to the agent and it does the code +
deploy; the self-service steps are below):

1. **Reproduce/fix** in the relevant repo.
2. **Branch → PR → CI → squash-merge to `master`.**
3. On merge: a new SemVer tag is created along with a **draft** GitHub Release, and staging
   deploys → verify the fix on `staging.slapstat.com` / `api.staging.slapstat.com`.
4. **Promote the new version to prod** by **publishing that draft release**. That is the whole
   step: `promote-to-prod.yml` runs on `release: published`, moves the app's `git_branch` to
   the tag, stamps `APP_VERSION` + `SENTRY_RELEASE`, deploys, and then greps the build log for
   the expected commit — so it fails loudly rather than reporting a promotion that shipped
   something else. Rollback is the same workflow via `workflow_dispatch` with an older tag.
5. **Mark the issue Resolved** in Sentry. If it recurs (regression), Sentry reopens it.

> **A 502 during a prod promote is now a signal, not noise.** Every production app has a
> health check (`/actuator/health`, `/` for the web), so Coolify keeps the old container
> serving until the new one answers. If users see 502s during a deploy, something is wrong —
> check whether the health check got switched off, or whether the image lost `curl`, which the
> probe runs inside the container. Before August 2026 the checks were disabled and a brief 502
> per promote genuinely was expected; that is no longer the case.

---

## 6. Common errors & what they mean

| Error in Sentry | Likely cause | First check |
|---|---|---|
| `Downstream service call failed` (`ResourceAccessException`) | a backend service was unreachable | is that service up? (Coolify → its container / health) |
| `Downstream service returned 5xx/401` | a backend returned an error or rejected the API key | the downstream's logs; the `*_INTERNAL_API_KEY` match |
| `Downstream unavailable` (502, from `handleDownstream`) | a wrapped downstream failure | the cause in the stack trace |
| `Unhandled exception` (500) | a genuine bug — unexpected exception | the stack trace line |
| Flyway / DB errors on startup | a migration or DB-connectivity issue | the service's startup logs + its Postgres |

---

## 7. Principles baked into this

- **Never silence an error:** every 5xx/fault logs at `ERROR` (→ Sentry). 4xx/expected
  outcomes (validation, not-found, not-connected) are *not* logged — so Sentry stays
  low-noise and an alert means a real fault.
- **One project, env-tagged:** all four backends report to the one Sentry project; filter by
  `environment` (staging/production) and read the service off the Java package.
