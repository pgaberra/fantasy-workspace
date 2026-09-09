# CLAUDE.md — fantasy (monorepo root)

Six-repo fantasy hockey application (SlapStat):

| Repo | Role | Port |
|---|---|---|
| `fantasy-web` | Angular 21 frontend | 4200 |
| `fantasy-bff` | Spring Boot 4 Backend-for-Frontend (auth, orchestration) | 8080 |
| `fantasy-db-service` | Spring Boot 4 persistence (users, projections, shares — Postgres) | 8086 |
| `fantasy-yahoo-service` | Spring Boot 4 Yahoo integration (per-user OAuth, league settings, **and the cached player read model** — identity + eligible positions + season stats, Postgres) | 8088 |
| `fantasy-espn-service` | Spring Boot 4 ESPN integration (leagues via the user's cookies, plus the stats Yahoo does not report, Postgres) | 8090 |
| `fantasy-projection-service` | Python/FastAPI projection model + NHL stat store (Postgres) | 8092 |

The web talks only to the BFF; the BFF talks to the other four. (The former
`fantasy-nhl-service` and `fantasy-player-service` were retired once all player data —
stats, positions and identity — came from Yahoo, with the player read model + sync folded
into yahoo-service. Nothing in the monorepo talks to them.)
Inter-service calls are authenticated with a shared `X-Internal-Api-Key` header — the one
exception is yahoo-service's OAuth callback (`/api/v1/yahoo/oauth/callback`), which Yahoo's
browser redirect hits directly and which is secured by a signed `state` parameter instead.
Each repo has its own `CLAUDE.md` for its own detail; this file holds what is shared.

## Service communication

All inter-service HTTP communication is **OpenAPI-first**:

- Every service exposes its spec (`/v3/api-docs` via springdoc; `/openapi.json` on
  projection-service).
- Consumers generate typed clients from the spec — never write hand-rolled HTTP clients.
- `fantasy-web` → `fantasy-bff`: TypeScript client via `ng-openapi-gen`
  (`npm run generate:api`).
- `fantasy-bff` → each downstream: Java model POJOs via the `openapi-generator` Gradle
  plugin, one task per service (`openApiGenerate` for db, plus `generateYahooClient`,
  `generateEspnClient`, `generateProjectionClient`).
- The consumer commits a **verbatim pinned copy** of the producer's spec under `specs/`,
  and CI fails if it drifts from the producer's `master`.

When a service changes its API: update the spec → regenerate the client → fix any
compile errors → open a PR. This ensures breaking changes are caught at compile time.

## Secrets & configuration

**Never commit a password, API key, token, or any secret to git — in any environment.**
This holds even for throwaway local-dev credentials, so the habit is absolute and we
never risk leaking (or reusing) a real one.

- Secrets come **only** from environment variables (`${DB_PASSWORD}`, `${INTERNAL_API_KEY}`,
  …) — no literal value and **no default** in `application*.yaml`. A missing var should fail
  fast, not silently fall back to a baked-in value.
- Non-secret connection details (host, port, database name, username) may be committed in
  the profile configs (`application-local.yaml`, `application-staging.yaml`); only the
  secret is withheld and supplied via env.
- The one place a local-dev password legitimately lives is `docker-compose.yml`, which
  *defines* the local database — that's infra setup, not app config.
- Spring profiles for running a service: `local` (docker-compose Postgres) and `staging`
  (the deployed DB). Run with `SPRING_PROFILES_ACTIVE=<profile> DB_PASSWORD=… ./gradlew bootRun`.

## Input validation

**Every service validates its own inbound data independently** — never trust that an
upstream caller (e.g. the BFF) validated correctly. Reject malformed input at the boundary
with Bean Validation, and give **every user-supplied string a `@Size(max=…)`** so an
oversized payload is rejected rather than processed or stored. The web mirrors those caps in
its forms as a UX convenience, never as a security boundary.

## Logging & error handling

**Never silence an error.** Every service's `@RestControllerAdvice` has a catch-all
`@ExceptionHandler(Exception.class)` that **logs the full stack trace** (`log.error`) and
returns a consistent `ErrorDto` — an unmatched exception must never surface as an opaque 500
with no server-side trace (a downstream failure was once undiagnosable because of exactly
this). **5xx / genuine faults** log at `ERROR` with the exception, so the trace reaches the
logs and Sentry; **4xx / expected client outcomes** (unauthorized, not-found, conflict,
validation) do **not** — they are normal and would just be noise. **Async / background work**
(scheduled syncs, CLI runs) never reaches the advice and must `try/catch` at its own
boundary. Each repo's `CLAUDE.md` adds only the cases peculiar to that service.

## Backlog / TODO list

The project's backlog — what Alexander means by **"my TODO list"** — is the GitHub
Project **"Fantasy Hockey"** (pgaberra project #1):
<https://github.com/users/pgaberra/projects/1> (`gh project view 1 --owner pgaberra`).
Cards are GitHub Issues across the repos, grouped by Status **Todo / In Progress /
Done**. When starting a card, move it to *In Progress*; put `Closes #NN` in the PR
description so the merge closes the issue.

## Say what you find

Building a feature or chasing a bug turns up things that weren't the task: a second bug
beside the one being fixed, a number that can't be right, a rule that contradicts another,
a decision in the code that looks like a mistake. **Tell Alexander about it, in the reply
you're already writing** — plainly, in a line or two, with what you saw and what it would
mean. His call, not yours.

That holds whether or not it is worth acting on now, and whether or not it is in scope. A
finding kept back because it "wasn't part of the ticket" is a finding nobody gets to weigh.
Report it and carry on with the task at hand — don't quietly widen the change to cover it,
and don't stop and wait for an answer unless the work genuinely can't continue without one.

## Fix from first principles

A problem almost always arrives with a solution already attached: the reporter's
workaround, the shape of the fix an issue proposes, the obvious patch at the line that
broke. Treat that as evidence about the pain, not as the spec. Before implementing, answer
three questions and put the answers in the PR description:

1. **Why did it happen?** Name the mechanism, not the symptom. A number that is wrong in one
   place usually means the definition lives in several; a rule that got bypassed usually
   means the invariant is enforced in one caller instead of at the boundary; a label nobody
   understands is usually a field nobody reads. Fix at the level that ends the class of bug,
   not the instance that was reported.
2. **What could be removed instead?** A column that cannot go stale because it is gone, one
   projection path instead of a third copy of the same formula, a constraint instead of a
   check somebody has to remember. Fewer moving parts wins unless something concrete needs
   the extra one.
3. **Is this the best solution, or just the proposed one?** Write down the alternative you
   considered and why you passed on it. If the better answer changes something a user sees,
   or something already shipped, give both options with a recommendation: that call is
   Alexander's, and the PR should make it cheap to take either way.

Three sentences is a complete answer. What matters is that the questions were asked before
the code was written, not that the PR body is long. When the path taken differs from the one
the issue proposed, that is a line for `DECISIONS.md`.

## Definition of done

A change is done when all of these hold. Iterate until they do, rather than reporting it
finished with a list of what is left.

1. **The repo's own checks pass locally** — all of them, not just the one you remember. Each
   repo's `CLAUDE.md` names them. (projection-service's CI runs `ruff check`, `black
   --check` and `pytest`, so `ruff format` alone proves nothing; a bare `mypy` is worth
   running on top, since CI does not.)
2. **New or changed logic has tests**, at the level that repo already tests at.
3. **If the API changed**: the spec is regenerated, the consumer's pinned copy under
   `specs/` is updated in the same change, and the generated client still compiles. The
   pinned-spec check blocks every bff and web PR, so drift gets caught either way — the
   point is to catch it before CI does.
4. **The PR title reads as the squash commit message**, and the PR is not stale
   (see [CI / workflow](#ci--workflow)).
5. **The PR body answers the three questions** in
   [Fix from first principles](#fix-from-first-principles).
6. **Non-obvious choices are recorded** (see [Decision log](#decision-log)).
7. **The last mile is verified in the same session, not assumed.** Merged is not deployed,
   deployed is not live, and ingested is not used:
   - A merge never reaches prod on its own; publishing the draft release does. A failed
     promotion rolls back and says nothing, so read the container's `APP_VERSION` rather
     than the release list.
   - A scheduled job is not running until it has been seen firing once.
   - Data that is synced but that nothing reads is not in the product. The goalie depth
     chart sat ingested and unused for weeks, and nothing anywhere said so.

   When switch-on has to wait, the session's last message says exactly what is not live and
   who flips it. The expensive failure here has never been built-wrong, it has been
   built-and-never-switched-on.

## Decision log

`DECISIONS.md` in this root holds the choices that span repos or live in the infrastructure,
one line each; every service repo keeps its own for its own. **Read it before re-opening a
settled question**, and append a line whenever you pick A over B, decline a dependency, or
stop because a rule here forbade something. The file's own header carries the format and the
one-line limit.

## CI / workflow

- Branch → push → PR → checks pass → **squash merge** to `master`.
- The **PR title is the commit message** — squash merge ignores the branch commits, so the
  title has to read as one (`feat: add X`, `fix: correct Y`). Rename it first with
  `gh pr edit <n> --title "..."` if needed, and never merge a PR titled "wip" or "draft".
- **Check the PR isn't stale before merging.** PR Checks tests the branch merged against
  whatever `master` was when the check last ran — not continuously, and not again after a
  merge. If `master` has moved since, merge it into the branch and let checks run again;
  otherwise the squashed result combines code that was never built or tested together.
  Nothing enforces this but whoever merges (branch protection needs GitHub Pro).
- `@claude` mentions on issues/PRs trigger the Claude workflow in each repo.

### Working in parallel — one worktree per agent

**Assume another agent is working in these repos right now.** Several sessions run against
the same clones, so the checkout you find is *not* yours: it may sit on someone else's
feature branch, with their half-finished edits in the working tree — and often dozens of
commits behind `master`, so read your own worktree rather than the shared checkout.

Before you change anything, move into **your own git worktree** — never work directly in the
shared checkout:

```
git -C <repo> fetch origin
git -C <repo> worktree add <path-outside-the-repo>/<short-name> -b <your-branch> origin/master
```

Put the worktree outside the repo (the session scratchpad is a good home) so it doesn't end
up in the other agent's file watcher or build output. Remove it when the PR is merged:
`git worktree remove <path>`.

Cut the branch from `origin/master` **explicitly**, as above. A bare `git checkout -b` cuts
from whatever HEAD happens to be, and if that's another agent's in-flight branch your PR
silently carries their commits into `master` alongside yours.

Five more rules that follow from the same problem:

- **Never `checkout`, `switch`, `stash`, `pull` or `reset` in the shared checkout.** It yanks
  the floor out from under whoever is editing there.
- **Stage explicit paths** — `git add <the files you changed>`, never `git add -A` or `-u`.
  Modified files you don't recognise are someone else's work; leave them alone.
- **Read the PR before merging** (`gh pr view <n> --json commits,files`). If it contains a
  commit or a file you didn't write, the branch was cut from the wrong base — fix that first.
- **Run `gh` from inside your own worktree** — not merely inside the sub-repo. `-R owner/repo`
  fixes which *repo* `gh` talks to, and from the monorepo root you need it or `gh` silently
  resolves the wrong one. But `gh pr create` also takes the *branch* from the directory you
  are standing in, and the shared checkout is normally sitting on another agent's in-flight
  branch. Being "inside fantasy-web" is therefore not enough: run it from your worktree, or
  pass `--head <your-branch>` explicitly.
  This is not hypothetical. A `gh pr create` run from the shared `fantasy-web/` opened a PR
  proposing to merge someone else's `wip/…` branch into `master`, under a title describing an
  entirely different change — the branch had been pushed correctly from a worktree; only the
  PR was created from the wrong directory. **Read back what you actually opened**
  (`gh pr view <n> --json headRefName,baseRefName,commits`) before you trust it; `gh pr close`
  undoes it cleanly.
- **Never pass `--delete-branch` to `gh pr merge`.** Deleting the branch it just merged means
  checking out `master` in the directory you are standing in, and the shared checkout is
  holding `master`, so `gh` stops with `fatal: 'master' is already used by worktree at …` —
  *after* the merge has already landed on GitHub. The output reads like the merge failed. It
  did not, and re-running it acts on a PR that is already merged. Merge without the flag,
  confirm with `gh pr view <n> --json state,mergeCommit`, then clean up yourself:
  `git worktree remove <path>`, `git branch -D <branch>`, `git push origin --delete <branch>`.

A fresh `fantasy-web` worktree needs `npm ci` and `npm run generate:api` before lint/test/build
will run, since `node_modules` and the generated `src/app/api` are not in git. The Gradle
services need nothing extra.
