# CLAUDE.md — fantasy (monorepo root)

Four-service fantasy hockey application:

| Repo | Role | Port |
|---|---|---|
| `fantasy-web` | Angular 21 frontend | 4200 |
| `fantasy-bff` | Spring Boot 4 Backend-for-Frontend (auth, orchestration) | 8080 |
| `fantasy-db-service` | Spring Boot 4 persistence service (users, Postgres) | 8086 |
| `fantasy-yahoo-service` | Spring Boot 4 Yahoo integration (per-user OAuth, league settings, **and the cached player read model** — identity + Yahoo eligible positions + season stats, Postgres) | 8088 |

The web talks only to the BFF. The BFF talks to db-service and yahoo-service. (The former
`fantasy-nhl-service` and `fantasy-player-service` were retired once all player data —
stats, positions and identity — came from Yahoo, with the player read model + sync folded
into yahoo-service.)
Inter-service calls are authenticated with a shared `X-Internal-Api-Key` header — the one
exception is yahoo-service's OAuth callback (`/api/v1/yahoo/oauth/callback`), which Yahoo's
browser redirect hits directly and which is secured by a signed `state` parameter instead.
Each repo has its own `CLAUDE.md`.

## Service communication

All inter-service HTTP communication is **OpenAPI-first**:

- Every service exposes its spec at `/v3/api-docs` (springdoc).
- Consumers generate typed clients from the spec — never write hand-rolled HTTP clients.
- `fantasy-web` → `fantasy-bff`: TypeScript client generated via `ng-openapi-gen`
  (`npm run generate:api` in `fantasy-web`).
- `fantasy-bff` → `fantasy-db-service`: Java model POJOs generated via
  `openapi-generator` Gradle plugin (`./gradlew openApiGenerate` in `fantasy-bff`).
  Committed spec lives at `fantasy-bff/specs/fantasy-db-service-openapi.yaml`.
- `fantasy-bff` → `fantasy-yahoo-service`: Java model POJOs generated via the same plugin
  (`./gradlew generateYahooClient` in `fantasy-bff`). Committed spec lives at
  `fantasy-bff/specs/fantasy-yahoo-service-openapi.yaml`. yahoo-service owns both the Yahoo
  OAuth integration and the cached player read model (skaters/goalies + a daily sync), so
  the BFF reads all player data from it.

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

## Backlog / TODO list

The project's backlog — what Alexander means by **"my TODO list"** — is the GitHub
Project **"Fantasy Hockey"** (pgaberra project #1):
<https://github.com/users/pgaberra/projects/1> (`gh project view 1 --owner pgaberra`).
Cards are GitHub Issues across the four repos, grouped by Status **Todo / In Progress /
Done**. When starting a card, move it to *In Progress*; put `Closes #NN` in the PR
description so the merge closes the issue.

## CI / workflow

- Branch → push → PR → checks pass → **squash merge** to `master`.
- `@claude` mentions on issues/PRs trigger the Claude workflow in each repo.

### Working in parallel — one worktree per agent

**Assume another agent is working in these repos right now.** Several sessions run against
the same clones, so the checkout you find is *not* yours: it may sit on someone else's
feature branch, with their half-finished edits in the working tree.

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

Three more rules that follow from the same problem:

- **Never `checkout`, `switch`, `stash`, `pull` or `reset` in the shared checkout.** It yanks
  the floor out from under whoever is editing there.
- **Stage explicit paths** — `git add <the files you changed>`, never `git add -A` or `-u`.
  Modified files you don't recognise are someone else's work; leave them alone.
- **Read the PR before merging** (`gh pr view <n> --json commits,files`). If it contains a
  commit or a file you didn't write, the branch was cut from the wrong base — fix that first.

A fresh `fantasy-web` worktree needs `npm ci` and `npm run generate:api` before lint/test/build
will run, since `node_modules` and the generated `src/app/api` are not in git. The Gradle
services need nothing extra.

### Merging PRs

GitHub squash merge uses the **PR title** as the commit message — the individual
branch commits are ignored. Before merging:

1. Ensure the PR title is a proper commit message (e.g. `feat: add X`, `fix: correct Y`).
   Rename it first with `gh pr edit <n> --title "..."` if needed.
2. Merge with an explicit subject so the commit message is never left to chance:
   ```
   gh pr merge <n> --squash --delete-branch \
     --subject "feat: describe the change (#<n>)" \
     --body "Optional longer description."
   ```

Never merge a PR titled "wip", "draft", or similar.

## Commit messages

No attribution trailers. `attribution.commit` and `attribution.pr` are set to `""` in
`~/.claude/settings.json` — this is enforced at the tool level.
