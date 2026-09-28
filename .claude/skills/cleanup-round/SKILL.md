---
name: cleanup-round
description: The weekly cleanup round, run locally by a desktop-app scheduled task. Removes worktrees, local branches and GitHub branches whose PR is merged, across the seven fantasy repos, and reports on fantasy-workspace#107. Never touches unmerged, unpushed or uncommitted work.
disable-model-invocation: true
---

# cleanup-round

**Goal:** a merged PR leaves nothing behind: no worktree, no local branch, no branch on GitHub.

Sessions open PRs that GitHub merges later through auto-merge, after the session has ended, so
nobody is left to clean up. By 2026-09-28 that had piled up to about twenty worktrees, 180 local
branches and 210 GitHub branches. GitHub now deletes a PR's branch on merge in all seven repos
(*Automatically delete head branches*); this round covers what GitHub cannot reach, the folders
and branches on Alexander's machine, and the GitHub branches from before the setting.

## How it runs

A scheduled task in the Claude desktop app ("Städrunda", `cleanup-round`), Mondays 10:05 Europe/Stockholm,
an hour after the Dependabot round. Its working folder is **`C:/Users/Alexander/cleanup-round`**,
not a repo, which holds:

- `cleanup_round.py`, which does all of the work and posts its own report on
  `pgaberra/fantasy-workspace#107` (locked). No judgement is involved, so no model decides what
  goes: the session only starts the script.
- `test_cleanup_round.py` (18 tests) and `.claude/hooks/test_cleanup_round_guard.py` (4).
- `.claude/settings.json`: every tool but Bash denied, `dontAsk` mode. The PreToolUse guard allows
  exactly `C:/Python312/python.exe C:/Users/Alexander/cleanup-round/cleanup_round.py [--apply]`.

Without `--apply` the script is a dry run that prints what it would remove; use that from any
session before changing the rules.

## What goes

Per repo, only when all hold:

- a PR from that branch, in the same repo (not a fork), was **merged more than a day ago**;
- **on GitHub**, the branch tip is exactly the PR's merged head; **locally**, the tip is that head
  or behind it (a branch updated on GitHub with `gh pr update-branch` leaves the worktree one
  merge commit behind). A commit after the merge, or one never pushed, keeps the branch;
- no open PR uses the branch name, and it is not `master`;
- for a worktree: not locked, `git status --porcelain` empty, and Windows lets the folder be
  renamed (it refuses while a process holds a file in it). The folder is deleted without
  following junctions, past the 260-character limit, then `git worktree prune`;
- a local branch goes only once no worktree has it checked out, so the shared checkout's branch
  stays whatever it is.

A PR closed without merging keeps its branch: that work may be wanted later.

Each repo runs on its own; an error in one is reported and the others carry on. Every run comments
on #107, including a run that removed nothing.
