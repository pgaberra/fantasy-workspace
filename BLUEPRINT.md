# Web Project Blueprint

A battle-tested blueprint for building a production web application, distilled from the
SlapStat fantasy-hockey project (Angular SPA + Spring Boot services on Coolify/Hetzner).
It is written for an AI agent (or human) starting a **new** project of the same kind:
follow it as the default, and deviate only with a documented reason.

**How to use this document:** treat every section as the project's starting convention.
Where a rule has a *Why*, the reasoning matters more than the letter — keep the intent
if circumstances differ. Don't cargo-cult scale you don't need (see §2 on when to split
services). As real decisions are made in the new project, record them in per-repo
`CLAUDE.md` files so future agents inherit them — this blueprint is the seed, not the
final documentation.

---

## 1. Product & repo philosophy

- **One repo per deployable service**, named `<product>-web`, `<product>-bff`,
  `<product>-<domain>-service`. A local "monorepo" is just a parent folder holding the
  clones; the parent folder is **not** a git repo (each service versions independently,
  CI runs per repo).
- **Every repo has a `CLAUDE.md`** at its root: tech stack, common commands,
  architecture map, conventions, CI description, deployment notes. It is the contract
  with future AI agents. Update it in the same PR that changes a convention.
- Shared cross-repo rules (secrets policy, merge policy, API-first rules) are repeated
  in each repo's `CLAUDE.md` under a "Monorepo conventions" heading, because agents
  usually see one repo at a time.
- **English everywhere in artifacts**: code, comments (rare — see §9), commits, PRs,
  issues, docs.

## 2. Architecture

```
Browser ──HTTPS──▶ Web (SPA, nginx)            ← the only thing users load
                     │  (JSON/HTTPS, JWT)
                     ▼
                   BFF (Spring Boot)           ← the only API the web talks to
                     │  (HTTP + X-Internal-Api-Key, Docker network)
        ┌────────────┼────────────────┐
        ▼            ▼                ▼
  db-service   integration-service   (more domain services…)
  (users, own  (3rd-party OAuth,
   Postgres)    cached read model,
                own Postgres)
```

Principles:

- **The web talks only to the BFF.** The BFF handles auth (JWT), shapes responses for
  the frontend, and orchestrates downstream calls. It holds **no business logic and no
  own database** — domain rules and data live in domain services.
- **Database per service.** No service reads another service's tables; all
  inter-service access is HTTP.
- **Inter-service auth** is a shared `X-Internal-Api-Key` header (per-pair env vars:
  the caller's `<SVC>_INTERNAL_API_KEY` must equal the callee's `INTERNAL_API_KEY`).
  Add a **startup guard** in the caller that verifies the key against the downstream
  on boot — a mismatch must fail loudly at deploy time, not as cryptic 401s later.
  The only unauthenticated inter-service exception: browser-redirect callbacks
  (e.g. OAuth) — secure those with a signed `state` parameter instead.
- **When to split a service:** start with `web + bff + db-service`. Add a dedicated
  service when a domain is clearly separable — the strongest signal is *integration
  with an external API that owns its own credentials/token lifecycle* (give it the
  cached read model for that data too). Don't pre-split.
- **Concurrency model (Java): virtual threads, never reactive.** Synchronous
  `RestClient` code on virtual threads gives reactive-class throughput with plain
  imperative code, and lets you mix blocking libraries freely. No `Mono`/`Flux`.

## 3. Tech stack

| Layer | Choice | Notes |
|---|---|---|
| Frontend | Angular (latest), TypeScript, RxJS | Standalone components, signals, OnPush default |
| FE testing | Vitest (via `ng test`), ng-mocks, jsdom | |
| FE quality | ESLint (angular-eslint + sonarjs, type-aware) + Prettier | Both enforced in CI |
| E2E | Playwright | Runs against deployed staging, daily — not a PR gate |
| Backend | Spring Boot (latest), Java (latest), Gradle | Virtual threads on; `RestClient` |
| API docs | springdoc OpenAPI | Spec is a first-class artifact (§5) |
| Auth | JWT (jjwt, HS256) access+refresh; Google/Facebook ID-token verification server-side (JWKS) | Client IDs are public; secrets never |
| BE quality | SpotBugs + FindSecBugs (build gate), JaCoCo, Qodana Community (weekly, report-only) | Never auto-apply Qodana fixes — verify each |
| DB | PostgreSQL, one per service; docker-compose for local dev | The compose file is the one legitimate place a local-dev password lives |
| Email | Resend (transactional: password reset etc.) | Verify the sending domain |
| Errors | Sentry via sentry-logback (backend ERROR logs → email alerts) | Tag environment |
| Hosting | Coolify on a VPS (e.g. Hetzner), Traefik proxy, Docker multi-stage builds | See §12 |
| Uptime | UptimeRobot (external) + a per-server internal health monitor | See §13 |

## 4. Environments

Three environments, two servers (staging box, prod box), one Coolify control plane
managing both:

- **local** — `ng serve` against a locally run BFF, or `npm run start:staging` (serve
  the SPA locally but point `apiUrl` at the staging BFF — requires staging CORS to
  allow `http://localhost:4200`). Backend: `SPRING_PROFILES_ACTIVE=local` with
  docker-compose Postgres.
- **staging** — full stack, deployed automatically on every merge to master.
  Staging-only version banner in the UI. E2E target. Throwaway test accounts.
- **production** — same Docker image and Spring profile as staging; only env vars
  differ. **Prod is promoted manually** (deliberate gate), staging is not.

Configuration rules:

- **Secrets come only from env vars** — no literal values and **no defaults** in
  `application*.yaml` or committed config. A missing secret must fail fast at startup.
  This is absolute, even for throwaway local-dev credentials, so the habit never slips.
- Non-secret connection details (hosts, ports, db names, usernames) may be committed
  per profile.
- The SPA gets environment values (API URL, OAuth client IDs) **at build time** via
  Docker build args injected into `environment.prod.ts`.
- **Spring gotcha:** list properties in profile YAMLs are replaced **wholesale**, not
  merged — any list (e.g. permitted URLs) redefined per profile must be kept in sync
  in every profile file.

## 5. API contracts (OpenAPI-first) — the load-bearing convention

All inter-service HTTP is contract-first. This is what catches breaking changes at
compile time instead of in production.

**Producers (every Spring service):**
- Complete `@Operation` / `@ApiResponse` / `@Tag` / `@Schema` annotations.
- **Every DTO field gets `@Schema(requiredMode = REQUIRED)`** unless genuinely
  optional. Without it, springdoc marks fields optional and the generated TypeScript
  makes everything nullable (`?`), poisoning the frontend with false nullability.
  Collections are never nullable.
- DTOs are Java `record`s. Prefer `Optional` over returning null.
- A **spec snapshot test** boots the app and asserts the committed `specs/openapi.yaml`
  matches live `/v3/api-docs.yaml`; regenerate deliberately with
  `./gradlew test -DupdateSpec=true` and commit. Pin the server URL in the OpenAPI
  config so the spec is deterministic.

**Consumers:**
- Generate typed clients — never hand-write HTTP calls, never hand-edit generated code:
  - web → BFF: `ng-openapi-gen` (`npm run generate:api`); generated `src/app/api/` is
    **gitignored** and regenerated in CI after `npm ci`.
  - BFF → downstream: `openapi-generator` Gradle tasks producing model POJOs
    (not committed; regenerated at build).
- Each consumer commits a **verbatim pinned copy** of every producer spec under
  `specs/`. Never reformat it (no prettier) — CI compares it byte-for-byte.
- **CI spec drift check** (first job in the PR pipeline): fetch the producer's spec
  from its `master` (fine-grained read PAT as a repo secret) and fail if the pinned
  copy differs. Drift is a *designed* red light: it forces the consumer to re-pin and
  regenerate immediately after a producer API change.
- Change workflow: update producer annotations → regenerate + commit snapshot → merge
  producer → in the consumer, copy the new spec verbatim, regenerate the client, fix
  compile errors → merge. Deploy producer before the consumer that depends on it.

## 6. Security

Most bullets below were paid for by a pre-launch security audit — treat them as defaults,
not aspirations. Recurring theme: **fail closed, trust nothing the client or a third party
sends, and make "expected abuse" cheap** — every public URL is bot-probed, so invalid
input and cancelled flows are normal traffic, not errors.

- **Never commit a secret. Ever.** (§4.) Rotate all production secrets before launch.

- **Fail closed, always.** Every auth/authz gate must treat *"the secret isn't
  configured"* as a fatal misconfiguration, never as "auth off". The shared-secret filter
  (§2) is the classic trap: if it silently skips itself when `INTERNAL_API_KEY` is blank,
  one forgotten env var serves the whole internal API — password hashes, third-party OAuth
  tokens — unauthenticated, and everything still *works*, so nobody notices until it's
  exploited. Enforce with a `@PostConstruct` guard that throws (context refuses to start)
  on a *blank* secret (distinct from §2's caller-side guard that the key *matches*
  downstream); keep the var defaultless; **compare secrets in constant time**
  (`MessageDigest.isEqual`, never `String.equals` — `equals` is a timing oracle). When you
  exempt paths from a gate (health probes, an OAuth callback), match a **decoded +
  normalised** path against an **exact allow-list** and reject any residual `..`/`;` — a
  raw `startsWith("/actuator")` prefix check is a traversal bypass
  (`/actuator/health/..;/../api/...`); decode inside a try/catch and treat malformed
  `%`-encoding as non-exempt (→ 401 key check, never a 500). (Making the filter mandatory
  means test slices need `@AutoConfigureMockMvc(addFilters=false)` and a dummy key in test
  config.)

- **Default deny.** The BFF security config ends in `anyRequest().denyAll()`. Two
  mechanisms for public endpoints:
  - *Infra/plumbing* (health, auth flow, swagger): a `permitted-urls` list property
    (mind the per-profile wholesale-replacement gotcha).
  - *Domain endpoints* (e.g. public read-only data): an explicit **method-scoped**
    matcher in code (`.requestMatchers(HttpMethod.GET, "…").permitAll()`) so the whole
    authorization posture is reviewable in one place and any new method on the path
    falls back to deny.

- **JWT + revocable refresh.** Short-lived access token + refresh token, HS256 with a
  ≥32-char env secret. The JWT filter is passive (invalid token ⇒ anonymous, let
  authorization decide). Admin role via an env-var email allowlist, carried as a JWT claim.
  Self-contained JWTs can't be individually revoked, so add a **per-user `token_version`**
  (int column, `NOT NULL DEFAULT 0`): stamp it into every *refresh* token as a claim, bump
  it on any "kill all sessions" event (password reset/change, email change, admin
  force-logout, suspected compromise), and on refresh reload the user and reject a token
  whose claim ≠ the current version (missing claim ⇒ stale ⇒ reject, fail-closed). Access
  tokens carry no version and stay a pure signature/expiry check (no per-request DB hit) —
  which is only safe because their TTL is short, so a bump fully locks out within minutes.

- **Social login**: verify ID tokens server-side against the provider's JWKS
  (signature, issuer, audience, verified email). Account model: find by subject →
  link by verified email → create password-less.

- **Verify self-asserted emails (soft gate).** A password registration proves nothing
  about mailbox ownership — a typo or an attacker binds an account to someone else's
  address, poisoning recovery and notifications. On register, email a **single-use,
  time-boxed** verification link and mark verified only when consumed; persist only a
  **SHA-256 hash** of the token, not the raw value (a fast hash is correct here — the token
  already carries ~256 bits of entropy, unlike a password). Default to a **soft gate**:
  auto-login but show a persistent "verify your email" banner with one-click resend;
  hard-gate only the capabilities that genuinely need a proven address (emailing other
  users, recovery/authority). Make verify/resend **enumeration-safe** (identical response
  for unknown / already-verified / valid; swallow send failures so timing never diverges).
  Auto-verify provider-proven emails on **both** account-create *and* link, and **backfill**
  existing rows to verified in the same migration (a bare `NOT NULL DEFAULT false` nags — or
  under a hard gate, locks out — your whole userbase on deploy). On the client, default the
  flag to **true** when absent (a session predating the feature, before the next refresh
  backfills it) — only an explicit `false` shows the banner.

- **Login is constant-work** (anti-enumeration). Always run exactly one password-hash
  comparison, even when the account is missing or password-less (OAuth-only) — against a
  **real dummy hash** precomputed once with the same encoder — and return one generic
  error. Skipping bcrypt for unknown emails makes "no such account" measurably faster than
  "wrong password": a timing oracle that enumerates your users. (Register itself still
  leaks existence; accept that and lean on rate-limiting rather than pretending it's closed.)

- **Validate inputs; *encode* to stop injection.** Every service validates its own input
  with Bean Validation; **every user-supplied string gets `@Size(max=…)`** (frontend
  `maxlength` mirrors it as UX, never as the boundary). But for injection safety, prefer
  **contextual output-encoding over input-validation**: never string-concatenate a value
  you don't fully own (user input, or a *third-party* identifier) into an outbound URL /
  SQL / shell string — pass it as a **URI-template variable** (`.uri("/x/{v}", v)`) / bound
  parameter so the layer escapes it. Regex-validating a third party's key *shape* is
  brittle (it 400s real values the day the provider changes format) and defends the wrong
  channel; encoding is format-agnostic and injection-safe. (Validate for *business* rules
  where you own the contract; rely on *encoding*, not validation, for injection safety.)

- **Rate limiting, two layers:**
  - In-app on auth endpoints (login/register/reset — brute-force and email-abuse).
  - Edge per-IP on every public app via Traefik's `rateLimit` middleware, attached
    through the platform's label config so it survives redeploys. Verify with a burst
    test (expect 429s) and remember multi-domain apps have **one router per domain** —
    attach the middleware to all of them.
  - **Key on the trusted hop, not the leftmost `X-Forwarded-For`.** XFF is
    client-appendable, so an attacker rotates a fake leading IP to land in a fresh bucket
    every request and defeat the limit. Derive the client IP from the hop *your* proxy
    appends (Nth-from-last, N = the number of proxies you actually run); fall back to the
    socket peer when the header is absent.

- **Public browser-redirect callbacks** (OAuth, webhook confirmations, magic links) are
  unauthenticated and bot-probed — design them for abuse:
  - **Always resolve to a redirect, never a 4xx/5xx page or JSON error.** Make provider
    params (`code`/`state`/`error`) optional and branch on them yourself, so a consent
    *denial* redirects gracefully instead of 500ing on required-param binding.
  - **Log by cause, not by catch site:** expected client outcomes (declined, params
    absent) at INFO, adversarial-but-expected input (forged/expired/tampered `state`) at
    **WARN**, only true server faults at ERROR — otherwise bots flood your ERROR→Sentry
    alerting at will. CR/LF-sanitize every request-controlled value before logging it.
  - **Make `state` single-use *and* server-bound, not merely signed.** A signature proves
    only that you signed the bytes — not freshness (a valid state replays) or provenance
    (you can't tell a state you issued from a plausible forgery). When building the
    authorize URL, mint a random nonce, persist it as a one-time row (nonce PK + subject +
    expiry) in the same transaction, and embed it in the signed state; in the callback
    verify the signature, then **atomically delete-on-use** the nonce (reject if absent,
    reject if its stored subject ≠ the state's) *before* exchanging the code. Purge expired
    rows on a timer. (Binding the state to the initiating browser via cookie, RFC 6749
    §10.12, is further hardening you may defer after weighing its narrow residual risk.)

- **Browser security headers from day one** — at the SPA's nginx/edge, on every response,
  each with the `always` flag (so error pages get them too): `X-Frame-Options: DENY`,
  `X-Content-Type-Options: nosniff`, `Referrer-Policy: strict-origin-when-cross-origin`,
  `Strict-Transport-Security: max-age=31536000; includeSubDomains`.

- **Content-Security-Policy — ship it, but never enforce-first.** An enforced policy that's
  even slightly too strict silently breaks third-party widgets and framework build tricks,
  and the breakage is invisible to code review (only live traffic reveals every host and
  inline handler the app truly needs). Roll out in stages: (1) deploy the full policy as
  `Content-Security-Policy-Report-Only` and watch real staging traffic through every flow
  (login/OAuth, fonts, images, embeds); (2) enforce the *structural* directives immediately
  in a separate real header (`frame-ancestors 'none'`, `base-uri 'self'`, `object-src
  'none'` — zero load-time risk, so don't leave them off); (3) flip the resource allowlist
  to enforcing once the report is clean. Set the header on the HTML document response only,
  at the edge. (See §15 for the two gaps that surface *only* under enforcement.)

- **Static analysis as a gate**: SpotBugs+FindSecBugs fail the build; Qodana runs
  weekly report-only. Never bulk-auto-fix lint suggestions — semantics can change
  (e.g. `Boolean.TRUE.equals(x)` → `x` breaks on framework-injected nulls).
- Swagger UI in deployed envs is env-gated (`SWAGGER_ENABLED`, default off in prod).

## 7. Error handling & resilience

**Backend — "never silence an error":**
- A `GlobalExceptionHandler` with a catch-all maps every exception to a consistent
  `ErrorDto` and **logs 5xx at ERROR with the stack trace** (this feeds Sentry
  alerting). 4xx are expected outcomes — never logged as errors.
- Any 5xx/fault that reaches a client **without** a server-side ERROR log is treated
  as a bug in itself.
- Downstream failures map to 502 with a stable machine-readable `code`
  (e.g. `DOWNSTREAM_UNAVAILABLE`). Prefer standard Java exceptions over custom ones.
- Timeouts on every downstream call.

**Frontend — assume every API call can fail** (the BFF may be down):
- Two interceptors: an outermost **retry interceptor** (statuses 0/502/503/504,
  2 retries with short backoff — absorbs blips, deliberately does *not* ride out a
  full restart) and an **auth interceptor** (on 401: refresh once, else logout).
- Every call site ends in one of these patterns:
  - *Page/data loads* → a shared `app-error-state` component ("couldn't load" + Try
    again button that reloads the resource).
  - *Discrete user actions* (create/delete/open) → a transient error toast via a
    signal-based `NotificationService` + an `app-toast` rendered once at the app root;
    reset any `isLoading` flag in the same error callback.
  - *Autosave* → flip an inline save status to `error` ("Couldn't save — changes are
    unsaved") instead of toast-spamming.
  - *Auth forms* → inline message, but distinguish server-unreachable (status 0/5xx →
    "can't reach the server") from a genuine 4xx ("invalid credentials") via a shared
    helper.
- A bare swallowed error callback is allowed only with a comment explaining why that
  failure genuinely isn't worth surfacing.
- Document this contract in the web repo's `CLAUDE.md` so it's enforced on every new
  call site.

## 8. Testing

| Layer | Tooling | Policy |
|---|---|---|
| FE unit | Vitest + ng-mocks (`MockBuilder`/`MockRender`) | No `any` in tests; prefer `toEqual`; mock services with explicit `vi.fn()` spies |
| BE unit/integration | JUnit 5, MockMvc, `@MockitoBean` for client interfaces | Integration tests never hit real downstreams |
| BE http clients | WireMock (standalone) | The only place downstream HTTP is exercised |
| Contract | Spec snapshot test (§5) | API changes fail the build until the spec is regenerated |
| E2E | Playwright against **deployed staging** | Daily + manual dispatch, not a PR gate (PR code isn't on staging yet). Keep tests independent, prefer role/id selectors, retire flaky tests rather than let them rot |
| Visual | Throwaway Playwright screenshot scripts | **Mandatory for every UI change:** verify at ~375px and desktop width; the app must never ship desktop-only |

Coverage target ~80% on backend service/controller packages. Every new service method
gets a happy-path and at least one failure-path test.

## 9. Code guidelines

**Both sides:** no code comments or doc comments unless explicitly requested — prefer
self-explanatory names. (Exception: a comment explaining *why* something surprising is
done, e.g. a deliberately swallowed error or a workaround with a link.)

**Angular:**
- Standalone components + signals; `inject()` (no constructor injection); OnPush.
- No legacy `[(ngModel)]`; use signal `model()`/`input()`/`output()`.
- Never discriminate unions by property existence — use an explicit discriminant field
  (`type: 'skater' | 'goalie'`).
- Components stay small; extract services for logic; API calls go through the generated
  client wrapped in a service, never raw `HttpClient` in components.
- Single-parameter lambdas without parentheses; descriptive names (no `val`, `list`).
- `npm run format` before every commit; CI runs `format:check`.

**Java/Spring:**
- Layered: controller → service → client; no cross-layer skipping. Clients are an
  interface + an `Http…` implementation using generated models.
- Records for DTOs (`dto/request`, `dto/response`); `Optional` over null; standard
  exceptions over custom ones.
- Keep endpoints under `/api/v1`; default authenticated (§6).

## 10. Design system (frontend)

- A **global CSS token system** in `styles.css`: colors (incl. semantic
  `--color-danger` etc.), spacing scale (`--space-1..6`), radii, shadows, text sizes,
  font weights, z-index scale, transition. **Never hardcode hex values or magic
  numbers in component CSS — use the tokens.**
- Reusable `.btn` classes (`btn-primary/secondary/danger`, `btn-sm/lg/block`) instead
  of per-component button styling. One shared font (e.g. Inter) loaded once.
- Component-scoped CSS otherwise; shared UI atoms (loading indicator, error state,
  toast, tooltip) live in `shared/` as standalone components.
- **Responsive floor:** mobile isn't the priority but must be *acceptable*. Sanity
  check every UI change at ~375px (breakpoint `max-width: 640px`). Wide tables get
  their own scroll viewport with compact sticky identity columns; the page body never
  scrolls horizontally.
- Landing page principle: **show the product, don't describe it** — embed the real
  editor/feature read-only or gated ("sign in to save") rather than writing sales copy.

## 11. CI/CD pipelines (GitHub Actions, per repo)

**PR gate (`pr-checks.yml`)** — required, on PRs to master:
1. **Spec drift check** first (§5) — consumer repos only.
2. Web: `npm ci` → `generate:api` → `lint` → `format:check` → `test` → `build`.
   Backend: `./gradlew build --no-daemon` (compiles, tests, SpotBugs, spec snapshot).

**Merge policy:**
- Branch → push → PR → checks green → **squash merge**. The PR title becomes the
  commit message, so it must be a conventional commit (`feat: …`, `fix: …`); merge
  with an explicit `--subject "type: … (#N)"`. Never merge a PR titled "wip".
- Conventional-commit titles drive a **SemVer auto-tag + GitHub Release on every merge
  to master** (`tag-on-merge.yml`: `feat` → minor, `fix`/`chore` → patch, `!` → major).

**Other automation:**
- Dependabot with grouped weekly updates (one PR per group). Investigate red ones —
  often a formatter bump needs `npm run format`, or a framework minor needs holding
  back with a note.
- An `@claude` mention workflow on issues/PRs for AI-assisted fixes.
- Daily E2E workflow against staging (§8).

## 12. Deployment & hosting

- **Coolify** (self-hosted PaaS) on VPS boxes: one staging server, one production
  server, one control plane managing both. Traefik is the ingress on each box.
- **Docker multi-stage builds:**
  - Web: Node build stage → nginx serving `dist/` with SPA rewrite (`/* →
    /index.html`); API URL & OAuth client IDs as build args.
  - Java: Gradle build stage → slim JRE image. **Gotcha:** JRE images have no `curl`
    — use an actuator/TCP health check or disable the platform's curl-based one.
- DNS: `app.example.com` (web) and `api.example.com` (BFF) per environment
  (`staging.` prefix for staging). Internal service URLs use Docker-network aliases
  and are never public (domain services get no public FQDN unless required).
- **Deploy model: staging auto-deploys on master push; production is promoted
  manually** (via the Coolify API/UI), with downstream-first ordering (BFF before web
  when the web depends on a new endpoint). Deploys are start-new-then-swap (~zero
  downtime). **Don't trust deploy metadata** — verify what prod actually serves
  (probe the endpoint, or grep the served JS bundle for a marker string).
- Edge rate limiting lives in Traefik labels managed through Coolify app config (§6)
  so it survives redeploys.
- Health checks: `/actuator/health` on every service (liveness for the platform;
  keep it public — it's also the uptime-monitor target).

## 13. Observability & alerting

- **Sentry** on every backend service via `sentry-logback`: ERROR logs become Sentry
  events → email. `SENTRY_DSN` env var, events tagged `staging`/`production`.
  Combined with §7's logging rules this means *every* genuine fault alerts.
- **Internal downtime monitor**: a tiny systemd-timer script per server pings each
  local service's health endpoint every ~2 min and raises a Sentry event on up/down
  *transitions* (reuses the same alert channel; no extra service to host).
- **External uptime monitor** (UptimeRobot free tier): catches what the internal one
  can't — the whole box being down. Two production monitors: HTTPS on the web root,
  and a **keyword** monitor on the API's `/actuator/health` matching `UP`
  **case-sensitively** (case-insensitive would match the "up" inside `"groups"` and
  mask a DOWN). 5-min interval, email alerts.
- **Version visibility**: each service exposes its version; the BFF aggregates a
  `/versions` endpoint (also reporting reachability per service); the web shows a
  staging banner with a tap-open panel (admin-only in production). Invaluable for
  "is prod actually running the new code?".

## 14. Working agreement (process)

- Backlog on a GitHub Projects board (Todo / In Progress / Done + Priority). Move the
  card when starting work; PRs reference issues (`Closes #N`) where applicable.
- Small, focused PRs; one concern each (a UI polish PR may absorb review iterations,
  but a product-default change gets its own commit and an honest PR title).
- **Data hygiene pre-launch:** with no real users, fix or delete bad data rather than
  writing tolerance code around it.
- After each task: delete local+remote feature branches, return to an up-to-date
  master. Before batch operations across repos, verify each repo is on a clean master.
- Documentation debt is handled in the same PR: convention changed ⇒ `CLAUDE.md`
  updated.

## 15. Stack gotchas (hard-won — check before debugging from scratch)

- **springdoc + Spring Boot minor bumps can corrupt the spec** (e.g. nullable `$ref`
  object schemas emitted as `type: "null"`, which breaks `ng-openapi-gen`). Fix with
  an `OpenApiCustomizer` shim that normalizes the schema, keep the spec byte-stable.
- **Spring Boot 4 ships Jackson 3**: `RestClient.body(com.fasterxml….JsonNode.class)`
  throws — deserialize into records (or `tools.jackson` types).
- **Missing `@Schema(requiredMode = REQUIRED)`** ⇒ every generated TS field is
  optional. Audit DTOs early.
- **Spring profile list properties replace, never merge** (§4).
- **Windows dev + CRLF**: enforce `.gitattributes` (`* text=auto` plus explicit
  `eol=lf` for scripts/specs, `eol=crlf` for `.bat`). Phantom modified files appear in
  `git status`; `git add -A` normalizes them away — verify with
  `git diff --cached --name-only` that only real changes are staged.
- **Rate-limit/auth 401s between services** are usually an env-var key mismatch —
  hence the startup guard (§2).
- **OAuth providers may return JSON with a wrong `Content-Type`** (e.g. Facebook's
  Graph API answering `text/javascript`) — configure the HTTP client/parser to accept
  it.
- **External monitors and health checks** must target endpoints that exist *and* are
  public — the API root returning 401 is not a health check.
- **Enforced CSP breaks two things that report-only and code review never show:**
  (1) a social sign-in widget loads its *stylesheet* from the provider's host (e.g.
  `accounts.google.com`) — allow it in **`style-src`**, not just `script-src`/`frame-src`,
  or the button renders unstyled; (2) Angular's prod build inlines critical CSS as
  `<link media="print" onload="this.media='all'">` (via beasties/critters) — that inline
  `onload=` is an event handler an enforced `script-src` blocks ⇒ **fully unstyled app**.
  Fix at the source, don't weaken `script-src`: set
  `optimization.styles.inlineCritical: false` in `angular.json` so no inline handler is
  emitted (verify in `dist/.../index.html`).
- **nginx `add_header` does not inherit into a `location` that sets its own `add_header`.**
  The moment a location adds (say) `Cache-Control`, it drops *all* server-level headers, so
  those responses ship without your security headers. Repeat them in every such location,
  add `always` (else nginx skips them on 4xx/5xx), and verify with `curl -I` against a
  cached asset and `index.html`, not just `/`. Behind a TLS-terminating proxy emit HSTS
  unconditionally — don't gate on nginx's `$scheme` (it's `http` behind the proxy, so the
  header would never be sent).
- **`Integer == Integer` for a version/counter claim is a boxing bug.** Java caches boxed
  `Integer`s only for −128..127, so `==` silently returns `false` past 127 *even for equal
  values* — a user past ~128 `token_version` bumps can no longer refresh (a valid token's
  claim compares unequal by reference and is wrongly rejected, forcing re-login). Compare as
  a primitive `int` so the boxed claim unboxes.
- **Appending a field to a delimiter-joined signed payload where an earlier field can itself
  contain the delimiter** (e.g. `subject:nonce:expiry`, and the subject may hold a `:`) —
  parse the fixed-count *trailing* fields from the RIGHT (`lastIndexOf`), never `split`
  left-to-right, or a delimiter inside the earlier field shifts every field and silently
  corrupts the parse.
- **`RestClient`/`RestTemplate` only percent-encode URI-template *variables*.** Concatenate
  an untrusted value into the template *string* and pass the whole thing to `.uri(...)` and
  nothing is encoded — the injection is unchanged. The load-bearing move is relocating the
  value into a `{var}` slot. Note the encoded `/` → `%2F` can be rejected by some
  proxies/WAFs (a downstream call that 404/400s *only* for slash-containing identifiers is
  the tell).
- **FindSecBugs' CRLF / log-injection taint analysis doesn't follow String transforms** — a
  value you *did* CR/LF-sanitize before logging still trips the detector, needing a targeted
  SpotBugs exclude even though the log call is genuinely safe.

## 16. Bootstrap checklist for a new project

1. Create repos: `<product>-web`, `<product>-bff`, `<product>-db-service` (+ integration
   services as needed). Seed each with a `CLAUDE.md` derived from this blueprint.
2. Backend skeletons: Spring Boot, virtual threads, security config with default-deny
   + JWT filter, GlobalExceptionHandler, actuator health, springdoc + spec snapshot
   test, SpotBugs/FindSecBugs, Sentry logback appender, docker-compose Postgres,
   `local`/`staging` profiles (secrets env-only, no defaults). Internal-key filter is
   **fail-closed** (startup guard, constant-time compare, exact-allow-list exemptions);
   users table carries a `token_version` column (§6).
3. Frontend skeleton: Angular standalone + signals, design tokens in `styles.css`,
   shared atoms (loading/error-state/toast), the two interceptors, generated API
   client wiring (`generate:api` from the pinned BFF spec), Vitest + ng-mocks, ESLint
   + Prettier. nginx image ships the security headers + a staged CSP (§6).
4. Auth: register/login/refresh + password reset (Resend) + social login if wanted;
   in-app rate limiting on the auth endpoints. Constant-work login (dummy-hash),
   refresh-token revocation via `token_version`, email verification (soft gate) (§6).
5. CI: `pr-checks.yml` per repo (with spec drift checks), `tag-on-merge.yml`,
   Dependabot config, `@claude` workflow, daily E2E workflow (once staging exists).
6. Hosting: Coolify apps per service per env; staging auto-deploy, prod manual
   promote; DNS + Let's Encrypt; build args for the web; internal Docker-network URLs;
   health checks.
7. Edge rate limiting on public apps (per-IP Traefik middleware); verify with a burst
   test.
8. Observability: Sentry projects + DSNs, internal health-monitor timer on each box,
   UptimeRobot monitors (web HTTPS + API health keyword `UP`, case-sensitive),
   `/versions` aggregation + staging banner.
9. Before launch: rotate all prod secrets, run the security checklist (§6), verify
   error-handling contract coverage (§7), confirm mobile floor (§10).
