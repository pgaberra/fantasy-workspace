# SlapStat — Infrastructure & Deployment Overview

How the whole thing hangs together: source code → build → deploy → serve, across
**production** and **staging**. Per-service deploy details live in each repo's own
`DEPLOYMENT.md`; **this file is the map of how the pieces connect.**

> TL;DR: code lives on **GitHub**, runs on two **Hetzner** servers, is built & deployed by
> **Coolify**, exposed through **Traefik** with **Let's Encrypt** TLS, and reached via
> **Cloudflare** DNS. **Staging auto-deploys** on every merge; **production is promoted
> manually** to a pinned version. While we're pre-launch, the apps are **locked to the
> owner's IP**.

---

## 1. The big picture

```
                         ┌─────────────────────────── GitHub (org: pgaberra) ───────────────────────────┐
                         │  fantasy-web · fantasy-bff · fantasy-db-service · fantasy-nhl-service ·       │
                         │  fantasy-yahoo-service   — each its own repo, squash-merged to `master`       │
                         │  CI: build/test + OpenAPI drift checks · auto-tag SemVer + Release on merge   │
                         └───────────────┬──────────────────────────────────────────────┬──────────────┘
                                         │ (GitHub App push events / git clone at build) │
                          auto-deploy ON │                                               │ manual promote
                                         ▼                                               ▼
   Cloudflare DNS                ┌──────────────────────┐                      ┌──────────────────────┐
   (A records, DNS-only) ─────►  │  STAGING server      │                      │  PRODUCTION server    │
   *.staging.slapstat.com        │  Hetzner 62.238.17.178│                     │  Hetzner 157.180.126.72│
   slapstat.com / api. / yahoo.  │                      │                      │  + runs Coolify itself │
                                 │  Coolify-proxy        │                      │  Coolify-proxy         │
                                 │   (Traefik + LE TLS)  │                      │   (Traefik + LE TLS)   │
                                 │      │                │                      │      │                 │
                                 │  ┌───▼────────────┐   │                      │  ┌───▼────────────┐    │
                                 │  │ web (nginx:80) │   │                      │  │ web (nginx:80) │    │
                                 │  │ bff (:8080)    │   │                      │  │ bff (:8080)    │    │
                                 │  │ db-svc (:8086) │   │   ← same shape →      │  │ db-svc (:8086) │    │
                                 │  │ nhl-svc (:8087)│   │                      │  │ nhl-svc (:8087)│    │
                                 │  │ yahoo  (:8088) │   │                      │  │ yahoo  (:8088) │    │
                                 │  │ 3× Postgres    │   │                      │  │ 3× Postgres    │    │
                                 │  └────────────────┘   │                      │  └────────────────┘    │
                                 │  (all on the internal │                      │  (internal `coolify`   │
                                 │   `coolify` network)  │                      │   docker network)      │
                                 └──────────────────────┘                      └──────────────────────┘

  The control plane: ONE Coolify instance (on the prod server) manages BOTH servers over SSH.
```

---

## 2. The platforms — what each does and why

### GitHub (org `pgaberra`) — source of truth & CI/CD trigger
- Five repos, one per service. Branch → PR → checks pass → **squash-merge to `master`**.
- The squash commit message **is the PR title**, so PR titles use Conventional Commits
  (`feat:`, `fix:`, `chore:`) — that drives the version bump (see §6).
- Coolify is connected via a **GitHub App** (source name `coolify-slapstat`) so it can clone
  the private repos at build time and receive push events for auto-deploy.

### Hetzner Cloud — the compute (two VPSes, Helsinki / `hel1`)
- **prod** `157.180.126.72` (~4 vCPU / 8 GB) — runs the production workloads **and** the
  Coolify control plane itself.
- **staging** `62.238.17.178` (~2 vCPU / 4 GB) — runs the staging workloads.
- Both are hardened (key-only SSH, fail2ban, unattended-upgrades) and sit behind a **Hetzner
  Cloud Firewall** (inbound 22/80/443 only). They're plain Linux boxes; everything else runs
  as Docker containers managed by Coolify.

### Cloudflare — DNS (and only DNS, for now)
- Maps the public hostnames to the server IPs via **A records**.
- Records are **DNS-only ("grey cloud", not proxied)**. This matters: Coolify/Traefik obtains
  TLS certificates from Let's Encrypt using the **HTTP-01** challenge, which needs the traffic
  to reach the server directly. Cloudflare's orange-cloud proxy would intercept that and break
  cert issuance.

### Coolify — the self-hosted PaaS (the "deploy brain")
- A self-hosted Heroku/Vercel-style control plane, running on the prod server, reachable at
  `https://coolify.slapstat.com`. **One instance manages both servers** (it connects to the
  staging server over SSH).
- What it does for each app: clones the repo at the right commit, **builds the Docker image**
  (from each repo's `Dockerfile`), injects **environment variables**, attaches the app to the
  internal Docker network, assigns **domains**, and tells Traefik to route + get TLS. It also
  runs the **Postgres** databases as managed containers.
- Organisation: project **`slapstat`** → two environments, **`production`** and **`staging`**.
- Driven by us via its REST API (token on the prod server at `/root/.coolify_token`).

### Docker + the `coolify` network — isolation & internal addressing
- Every app and database runs as a container on a shared per-server Docker network called
  `coolify`. Containers talk to each other over this private network — **not** over the public
  internet.
- Internal services are reachable by **stable network aliases** instead of unstable container
  names: `db-service:8086`, `nhl-service:8087`, `yahoo-service:8088`. That's how the BFF finds
  them regardless of redeploys.

### Traefik (`coolify-proxy`) — reverse proxy + TLS terminator
- One per server (Coolify deploys it). It's the single entry point for ports 80/443.
- Routes an incoming hostname (e.g. `api.slapstat.com`) to the right container, terminates
  HTTPS, and **provisions/renews Let's Encrypt certificates** automatically.

### Let's Encrypt — free TLS certificates
- Traefik requests certs via HTTP-01 (served on port 80). Auto-renews (~every 60–90 days) as
  long as port 80 is reachable from the internet (see the access-gate note in §8).

---

## 3. The five services

The web app talks **only** to the BFF. The BFF orchestrates the backend services. Backend
services never talk to each other.

| Service | Tech | Port | Public? | Database | Purpose |
|---|---|---|---|---|---|
| **fantasy-web** | Angular → nginx | 80 | ✅ `slapstat.com` | — | The UI (a static SPA). |
| **fantasy-bff** | Spring Boot (Java) | 8080 | ✅ `api.slapstat.com` | — | Backend-for-Frontend: auth (JWT/Google), orchestrates the backends, shapes responses for the UI. The only backend the web calls. |
| **fantasy-db-service** | Spring Boot | 8086 | ❌ internal | own Postgres | Owns users + saved projections (the app's database layer). |
| **fantasy-nhl-service** | Spring Boot | 8087 | ❌ internal | own Postgres | Mirrors NHL player/roster/stats data (synced from the public NHL API). |
| **fantasy-yahoo-service** | Spring Boot | 8088 | ⚠️ `yahoo.slapstat.com` (OAuth callback only) + internal alias | own Postgres | Per-user Yahoo Fantasy OAuth + league data; stores tokens encrypted. |

- **Internal services** (`db`, `nhl`) have **no public domain** — only the BFF reaches them
  over the `coolify` network, authenticated with a shared **`X-Internal-Api-Key`** header.
- **yahoo-service** is the exception: it needs a public domain because Yahoo's OAuth redirect
  hits it from the user's browser. Every `/api/**` endpoint still requires the internal API
  key; only `/api/v1/yahoo/oauth/callback` is exempt (it's secured by a signed `state`).
- **Separate Postgres per service** (separation of concern). Schemas are owned by **Flyway**
  migrations that run on each service's startup.

---

## 4. Domains (Cloudflare → which server / container)

| Hostname | → Server | → Container | Notes |
|---|---|---|---|
| `slapstat.com`, `www.slapstat.com` | prod | web | the app |
| `api.slapstat.com` | prod | bff | the API |
| `yahoo.slapstat.com` | prod | yahoo-service | OAuth callback |
| `staging.slapstat.com` | staging | web | staging app |
| `api.staging.slapstat.com` | staging | bff | staging API |
| `yahoo.staging.slapstat.com` | staging | yahoo-service | staging OAuth callback |
| `coolify.slapstat.com` | prod | Coolify | the deploy dashboard |

All are **A records, DNS-only**. `db-service` / `nhl-service` are intentionally absent (internal only).

---

## 5. How a request flows

**Loading the app:** browser → Cloudflare DNS resolves `slapstat.com` → server IP → Traefik
(terminates TLS) → web (nginx) serves the Angular bundle. The bundle has the API URL
(`https://api.slapstat.com`) **baked in at build time**.

**An API call:** browser → `api.slapstat.com` → Traefik → BFF. The BFF validates the user's
**JWT**, then (if needed) calls `http://db-service:8086` / `http://nhl-service:8087` /
`http://yahoo-service:8088` over the internal network with the `X-Internal-Api-Key` header,
shapes the result, and returns it.

**Yahoo connect:** browser → BFF `POST /api/v1/yahoo/connect` → yahoo-service builds a Yahoo
consent URL → browser goes to Yahoo → Yahoo redirects back to
`https://yahoo.slapstat.com/api/v1/yahoo/oauth/callback` → yahoo-service exchanges the code for
tokens (using the Yahoo **client secret**), stores them **encrypted** (AES-GCM), and redirects
the browser back to the web app.

---

## 6. CI/CD — from merge to running

### On every Pull Request
`.github/workflows/pr-checks.yml` runs build + tests (and lint/format for the web). A **spec
drift check** also runs: the BFF pins copies of each backend's OpenAPI spec, and the web pins
the BFF's spec — CI fails if a pinned copy is stale vs. the upstream `master`. This catches
breaking API changes at compile time. (Needs a `SPEC_READ_TOKEN` PAT with read access to the
other repos.)

### On merge to `master`
1. `.github/workflows/tag-on-merge.yml` reads the squash commit (= PR title) and creates a
   **SemVer tag + a DRAFT GitHub Release**: `feat:` → minor, `fix:`/`chore:`/anything → patch,
   `BREAKING CHANGE`/`!` → major. Every merge gets a tag; versions are **per-repo** (baseline
   `v0.1.0`). The release stays a draft — it is a *candidate*, not a shipment.
2. **Staging deploys**, via the same workflow: it stamps `APP_VERSION` on the staging app and
   redeploys it through `/root/set_staging_version_forced.sh`.
3. **Production does NOT move.** Prod apps have `auto-deploy = OFF` and a pinned commit.

### Promoting to production (publish the release)
**Publishing a version's GitHub Release is the promotion.** That is the one deliberate act;
nothing else moves production. `promote-to-prod.yml` runs on `release: published` (and still
accepts a manual `workflow_dispatch` with a tag, which is how you roll back to an older one).

It resolves the tag to its commit and calls `/root/promote_forced.sh <repo> <sha> <version>`
over a restricted SSH key. That script moves the app's **`git_branch` onto the release tag**,
verifies the move stuck *before* deploying, stamps `APP_VERSION` + `SENTRY_RELEASE`, deploys,
and then greps the **build log** for the expected commit — failing loudly otherwise. Prod app
UUIDs live in `/root/prod_app_uuids.txt`.

> **What actually pins production — measured on this instance, 2026-08-09.** Coolify's
> **"Commit SHA" field (`git_commit_sha`) is inert**: staging-espn-service was set to
> `2b4affe` and deployed, and Coolify built `06bc9a0` (the master tip) anyway. What *is*
> honoured is **`git_branch`**. Put a tag there and Coolify clones `-b <tag>`, lands in
> detached HEAD and builds exactly that commit — the same service on `git_branch=v0.0.2`
> built `2b4affe` with master untouched.
>
> So an app on `git_branch: master` rebuilds **whatever master has become** the next time
> anyone redeploys it — no release, no promotion, no warning. That is how production ended up
> running `master` in August 2026 while its "pin" still read `v0.83.0`, and why every promotion
> moves the branch to an immutable tag instead. The protection lives in that one field: if an
> app's `git_branch` is ever set back to a branch name, it will follow that branch again.
>
> The old `/root/promote_prod.sh` pinned only the inert commit field and is now `.deprecated`.
> Its August run is what shipped the wrong code: it stamped `APP_VERSION=v0.83.0`, pinned
> `bf1c0c4`, and deployed — and Coolify built `master` instead. That is why the bundle reported
> `v0.83.0` while running `v0.90.7` code: **the version label was the release someone intended
> to ship, and the code was whatever master happened to be.** A promotion that silently ships
> something else is exactly what the build-log check now catches.
>
> Env values are updated in place with `PATCH` (verified to preserve `is_buildtime`) rather
> than `set_env.py`'s delete-and-recreate, which discards whatever flags a variable carried and
> falls back to Coolify's defaults.

**Typical release flow:** merge PRs → staging updates + a draft release appears (e.g.
`v0.2.0`) → test on staging → publish that release → prod is promoted and verified. To roll
back, run `promote-to-prod` manually with an older tag.

### OpenAPI-first
All inter-service HTTP uses **generated typed clients** from each service's OpenAPI spec
(`/v3/api-docs`, pinned in `specs/`). Change an API → update the spec → regenerate the client
→ fix compile errors. The drift checks (above) enforce this.

---

## 7. Configuration & secrets

- **Never in git.** All secrets come from environment variables set in Coolify per app, or
  from files on the servers.
- **What's secret:** DB passwords, `JWT_SECRET`, the `*_INTERNAL_API_KEY` shared keys (BFF ↔
  each backend), `YAHOO_CLIENT_SECRET`, `YAHOO_STATE_SECRET`, `TOKEN_ENCRYPTION_KEY`.
- **Per-environment isolation:** staging and prod use **independent** secrets — nothing shared.
- **Where they live on the servers (prod):**
  - `/root/.coolify_token` — Coolify API token.
  - `/root/.slapstat_secrets` — prod-generated keys (internal API keys, JWT, DB + Yahoo).
  - `/root/.slapstat_staging_secrets` — the staging equivalents.
- **Non-secret config** (service URLs, ports, DB host/name/user, Google **client ID** which is
  public by design) may live in committed `application*.yaml` / build args.
- **Build-time vs run-time:** the web is a static SPA, so its config (`API_URL`,
  `GOOGLE_CLIENT_ID`) is injected into the bundle **at build time** (Docker build args). The
  Java services read config from **run-time** env vars.

---

## 8. Networking & security

- **Hetzner Cloud Firewall:** inbound limited to 22 (SSH), 80, 443.
- **Internal services not exposed:** `db-service` / `nhl-service` have no public domain; only
  reachable on the internal `coolify` network.
- **Service-to-service auth:** shared `X-Internal-Api-Key` header (a perimeter check between
  trusted services, not per-user auth).
- **User auth:** the BFF issues JWTs (HS256); Google sign-in verifies Google ID tokens; Yahoo
  is a separate per-user OAuth handled by yahoo-service.
- **Dev-phase access gate (pre-launch):** while the app isn't public, **HTTPS (:443) on both
  servers is locked to the owner's IP** via host iptables on Docker's `DOCKER-USER` chain
  (script `/root/ip-allowlist.sh`, re-applied on boot by the `ip-allowlist.service` systemd
  unit). **Port 80 stays open** so http→https redirects and Let's Encrypt renewal keep working;
  **SSH is untouched.**
  - Change the allowed IP: `ALLOW_IP=<new-ip> /root/ip-allowlist.sh` on both servers.
  - **Go public** (at prod launch): `FLUSH=1 /root/ip-allowlist.sh` + `systemctl disable
    ip-allowlist.service` on the prod server (leave staging locked).
  - **Gotcha:** the gate would otherwise block GitHub's webhook servers (breaking Coolify
    auto-deploy), so prod's `:443` also allows GitHub's hook IP ranges — that's how staging
    still auto-deploys while the app is private.

### Observability & alerting (Sentry)

The four backend services forward every **ERROR-level log** (with stack trace) to **Sentry**
(`sentry-logback` appender; `SENTRY_DSN` / `SENTRY_ENVIRONMENT` env, and `SENTRY_RELEASE` = the
version on prod). A genuine fault → a grouped Sentry issue → an **email**. Only real faults log
at ERROR (4xx outcomes don't), so alerts stay low-noise.
**→ Got an alert? How to debug it: [`TROUBLESHOOTING.md`](./TROUBLESHOOTING.md).**

### Usage analytics (PostHog)

Sentry answers *"did something break?"*. **PostHog** answers *"is anyone using this, and where
do they get stuck?"* — the two don't overlap. It runs on **PostHog EU Cloud** (Frankfurt, free
tier), with **separate projects for staging and production** so our own testing never lands in
the real numbers. The project key is public and injected into the web bundle at build time via
the `POSTHOG_KEY` build arg (empty ⇒ analytics off, and `posthog-js` isn't even fetched).

- **Ingested through our own domain.** The web's nginx proxies `/ingest/*` → `eu.i.posthog.com`,
  so the CSP stays at `'self'` and ad blockers have no third-party host to block (they would
  otherwise silently remove an unknown share of the traffic we're counting). That proxy's
  `X-Forwarded-For` is load-bearing — see below.
- **Consent.** A banner runs PostHog's `on_reject` cookieless mode: accept ⇒ cookies + full
  analytics; decline ⇒ still counted, but via a privacy-preserving server-side hash of
  IP + user agent, so declining doesn't distort the visitor numbers. **This is why
  `X-Forwarded-For` matters**: without the real client IP, every declining visitor would hash
  to the same "person". **Cookieless mode must also be enabled in the PostHog project
  settings**, or those events are silently discarded server-side.
- **Identity** is the account UUID (the JWT's `sub`), never the email.
- **Off by default:** autocapture and session replay. Both are deliberate later steps with
  their own privacy review — replay would otherwise record sign-up forms.
- Frontend JS errors are **not** yet reported anywhere (there's no `@sentry/angular` in the
  web) — a real remaining gap, separate from analytics.

**→ Per-repo detail: [`fantasy-web/DEPLOYMENT.md`](./fantasy-web/DEPLOYMENT.md).**

---

## 9. Operational runbook (common tasks)

| I want to… | How |
|---|---|
| Ship to **staging** | Just merge the PR to `master` — staging deploys + a tag and a **draft** release are created. |
| Ship to **production** | **Publish that version's GitHub Release.** `promote-to-prod.yml` pins, deploys and verifies. |
| **Roll back** prod | Run `promote-to-prod` manually (`workflow_dispatch`) with the older tag. |
| Check prod isn't drifting | `check_prod_pins.sh` (in this repo, not installed) — copy it to the prod server and run it; it fails if any app is on a branch rather than a `vX.Y.Z` tag, or shows webhook-triggered deployments. |
| Refresh **NHL data** | `POST /api/v1/sync` on the nhl-service (API-key protected); re-run after rosters update. |
| **Change** the allowed IP (dev gate) | `ALLOW_IP=<ip> /root/ip-allowlist.sh` on both servers. |
| **Go public** (launch) | `FLUSH=1 /root/ip-allowlist.sh` + disable `ip-allowlist.service` on prod. |
| See versions | Each repo's tags / GitHub Releases (`vX.Y.Z`). |
| Operate Coolify | `https://coolify.slapstat.com`, or its REST API via the prod server. |
| **Debug a backend error** (Sentry alert) | Open the Sentry issue → triage → fix → deploy. Full runbook: [`TROUBLESHOOTING.md`](./TROUBLESHOOTING.md). |

---

## 10. Current status (2026-06-14)

- Both environments fully deployed and healthy (web, bff, db, nhl, yahoo on each).
- Versions: backends at **`v0.2.x`** (bff `v0.2.1`, db/nhl/yahoo `v0.2.0`); web `v0.1.1`. Prod
  is pinned to those; staging follows `master`.
- **Error alerting: Sentry live on both envs** (ERROR logs → email; prod tagged with the
  version). See [`TROUBLESHOOTING.md`](./TROUBLESHOOTING.md).
- Yahoo integration: backend live + OAuth verified end-to-end; the web "Connect Yahoo" UI is a
  separate backlog item ([fantasy-web#65](https://github.com/pgaberra/fantasy-web/issues/65)).
- Access: **private** — HTTPS locked to the owner's IP until prod launch.
- Backlog lives in the GitHub Project **"Fantasy Hockey"** (pgaberra #1).

> Per-service specifics: see each repo's `DEPLOYMENT.md` and `CLAUDE.md`.
