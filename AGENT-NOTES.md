# AGENT-NOTES — the incidents behind the root CLAUDE.md rules

Why the rules in `CLAUDE.md` read the way they do. This file is **on-demand context**:
read the relevant section when a rule seems odd or is about to be bent — not by default.
The stories were moved out of `CLAUDE.md` because that file rides in every AI request in
every repo, so its narrative was a per-request token cost.

## Why secrets have no exceptions, even for throwaway credentials

A baked-in "temporary" local-dev password is indistinguishable from a real one in a diff,
and one lazy default is how real secrets start leaking — or get reused. Nobody audits
whether the throwaway one was ever real, so the habit is kept absolute instead.

## Why an unmatched exception must never be an opaque 500

A downstream failure was once undiagnosable because a service returned clean 500s with no
server-side trace. Hence the catch-all handler, the full stack trace at ERROR, and the
consistent `ErrorDto`. The 4xx carve-out exists so normal client outcomes don't drown the
signal in noise.

## The goalie depth chart

Data that is synced but that nothing reads is not in the product: the goalie depth chart
sat ingested and unused for weeks, and nothing anywhere said so. Hence "the last mile is
verified in the same session" — the expensive failure here has never been built-wrong, it
has been built-and-never-switched-on.

## Releases and APP_VERSION

Merged is not deployed; publishing the draft release deploys. Web and projection-service
can only be checked by Coolify's word, and releases tagged before 2026-09-11 run the old,
silent workflow — so the container's `APP_VERSION` is the source of truth, not the release
list. A failed promotion rolls back to the old container and opens a
`prod-promotion-failed` issue in the repo.

## Why the pinned-spec check only blames the branch

`check-pinned-spec.sh` fails a PR that itself put the pin out of step with the producer's
`master`, and only warns when the base branch was already behind. Blaming the base would
turn every PR after a producer change red for reasons its author cannot fix, and would
invite drive-by re-pins in unrelated PRs. Staleness is noticed by the scheduled
`spec-freshness.yml` instead, and re-pins land as their own PRs.

## The retired services

`fantasy-nhl-service` and `fantasy-player-service` were retired once all player data —
stats, positions and identity — came from Yahoo; the player read model and its sync were
folded into yahoo-service. Nothing in the monorepo talks to the old services, so
references to them in old issues or DECISIONS lines are history, not a hint that they
should come back.

## The gh-pr-create-from-the-wrong-directory incident

A `gh pr create` run from the shared `fantasy-web/` checkout opened a PR proposing to
merge someone else's `wip/…` branch into `master`, under a title describing an entirely
different change. The branch had been pushed correctly from a worktree; only the PR was
created from the wrong directory. Hence: run `gh` from your own worktree (or pass
`--head <your-branch>`), and always read back what you actually opened.

## The --delete-branch incident

`gh pr merge --delete-branch` checks out the merged branch's target in the directory you
stand in. When the shared checkout holds `master`, gh stops with `fatal: 'master' is
already used by worktree at …` — *after* the merge has already landed on GitHub. The
output reads like the merge failed; it did not, and re-running it acts on a PR that is
already merged. Hence: merge without the flag, confirm the merge, clean up by hand.

## The Sentry round's shape

The round runs as a Claude desktop scheduled task on Alexander's subscription — he
declined per-token API spend (DECISIONS.md, 2026-09-10). Because it runs with his own
credentials, it never merges, deploys, touches a server or a database, or silences an
alert: those limits are the design, not a detail. The run-log issue exists because a
scheduled job doing nothing looks exactly like a quiet day; its full rules live in the
`sentry-triage` skill.
