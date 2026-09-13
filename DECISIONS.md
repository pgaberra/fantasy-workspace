# Decision log

Non-obvious choices, one line each, so nobody re-derives them next week:

```
[YYYY-MM-DD] <repo or "monorepo">: <what was decided> — <why, and what was rejected>.
```

**Read this before re-opening a settled question.** If a line here answers the choice in
front of you, follow it or change it deliberately; don't quietly decide the other way.

**Append when you pick A over B**, decline a dependency, or stop because a rule in a
`CLAUDE.md` forbade something. Not for what the code already says: a decision belongs here
when the code shows *what* was chosen and nothing shows *why*, or when the option that was
rejected left no trace.

Rules that keep this file readable:

- **One line.** If it needs a paragraph it needs an issue or a PR body, and the line links
  to that. A decision log that grows paragraphs stops being read, and an unread log is
  worse than none: it looks like the question was answered.
- **Name the rejected option.** "Chose X" is a note; "chose X over Y because Z" is a
  decision.
- **Append at the end**, newest last. Two agents appending at once conflict on the last
  line; the resolution is always to keep both lines.
- **Per repo, not here.** A decision about one service goes in that repo's own
  `DECISIONS.md` (create it with your first line), in the same PR as the change it
  explains. This file is for choices that span repos or live in the infrastructure.

The log starts here, so a missing entry is not evidence that nothing was decided: older
choices live in git history and in the `CLAUDE.md` rules they turned into.

---

[2026-08-31] fantasy-bff: a premium game range is refused by the BFF, not merely hidden in the web (#187) — the web keeps badge, padlock and build switch apart for UX, but a hidden control is not a gate, and the entitlement has to hold for any caller of the API.
[2026-09-09] monorepo: adopted this log, plus "Fix from first principles" and "Definition of done" in the root `CLAUDE.md` — taken from the Accounted repo, whose own log had drifted into paragraphs, hence the one-line rule above; the loop/cron playbook and the CI ratchet guard from the same source were left for later.
[2026-09-09] monorepo: dropped the em dash rule for app copy, from CLAUDE.md and the slapstat-copy skill (#36) — it cost more in correction than it bought, and its "at most one per screen" half was never checkable from one file; narrowing it to short copy only was rejected as three files still policing one character, so keeping prose from turning breathless is the slapstat-copy voice section's job now.
[2026-09-10] monorepo: the Sentry round runs locally as a Claude desktop scheduled task on Alexander's subscription, not as a GitHub Action on an Anthropic API key — he declined per-token spend; the price is that it runs with his own credentials, so it starts in its own folder (C:/Users/Alexander/sentry-triage) whose PreToolUse guard blocks servers, databases, credentials, network egress and its own settings, because deny rules only match the usual spelling of a command and the Claude Code sandbox does not run on native Windows.
[2026-09-10] monorepo: em dashes are banned in app copy again, enforced by fantasy-web's `npm run check:copy` (fantasy-web#593) — reverses the 2026-09-09 entry above: that rule was a ration, costly to police by hand and half of it uncheckable from one file; this one is a flat ban a script checks on every PR, so neither objection applies.
[2026-09-11] bff + web: a pool reconciliation reports the ids of the rows it added (`poolReconciliation.addedPlayerIds`), replacing the count (fantasy-bff#216, fantasy-web#618) — the web narrows the table to those rows from the notice, which a count cannot do; the count was dropped rather than kept beside the list because two fields that must agree is one more than needed, and a stored per-row marker was rejected because nothing defines when it would be cleared.
[2026-09-11] db + bff + web: the players a pool reconciliation added are stored on the projection (`settings.unacknowledgedNewPlayerIds`) until the owner presses "Got it", replacing the one-read `poolReconciliation` (fantasy-db-service#104, fantasy-bff#218, fantasy-web#625) — Alexander wanted the notice to survive a reload; localStorage per projection was rejected because the notice would only show on the device that opened the projection first, and the entry above rejected a stored marker only for want of a defined clear, which the acknowledgement now is.
[2026-09-11] monorepo: `projection-sync.sh` finds its container by the Coolify label `coolify.serviceName` ending in `-projection-service`, replacing staging's hard-coded application UUID, so one file serves staging and production (#50) — reading the UUID from the host's `/root/health-monitor.conf` was rejected because it moves the per-host constant into a second hand-copied file and makes that file's row name an interface of the sync; a renamed Coolify app fails the lookup loudly every night, and `--find-container` checks it at install.
[2026-09-11] monorepo: a failed promotion opens a `prod-promotion-failed` issue in its own repo, from six identical copies of `promote-to-prod.yml` rather than one reusable workflow here (fantasy-workspace#30) — the repos are private with Actions access set to none, so sharing needs a settings change in all seven, and it would put every prod deploy behind this repo's master; one issue in this repo was rejected because the default token cannot write across repos and a PAT is one more secret.
[2026-09-11] monorepo: `projection-sync.sh` runs `projection game-logs` (the season with games) only in season, from the morning after the NHL's published opening night (`projection season-underway`, 29 September for 2026-27) to June, and `projection schedule` (the season projected) every night (#53, fantasy-projection-service#164, #165) — the logs feed Who's hot and the schedule is what a return date and opening night are read off, since a season's logs stop at last night; the October month rule was rejected because 2026-27 opens in September; the schedule runs year-round at Alexander's call, so a summer projection counts February return dates on the coming season's own calendar rather than on last season's Olympic break, and a season the NHL has not published yet is a success rather than a failure; year-round game logs were rejected as a nightly re-fetch of a finished season.
[2026-09-11] monorepo: a failed nightly sync is retried once, by `projection-sync-retry.timer` at 16:30 UTC reading a state file the run writes, and reaches Sentry only if the retry fails too; the morning's failures stay in the journal (#53) — Alexander's call, since most failures fix themselves within hours (MoneyPuck's file for a season that opened the evening before) and an alert per transient trains everyone to ignore the alerts; a retry loop inside the run was rejected because it holds the unit open for hours against its 90-minute cap, and an `OnFailure=` hook scheduling a transient timer because that timer is invisible in the repo and does not survive a reboot; a morning failure no retry followed is reported by the next run, so a missing retry timer cannot make failures silent.
[2026-09-11] monorepo: `BLUEPRINT.md` is folded into `INFRASTRUCTURE.md` (one level above the checkout, outside git since #24), now the single blueprint for the next app, with the architecture and infra decisions and their reasons in Part I and SlapStat's own servers, uuids, runbook and status in Part II — the two covered the same decisions and had drifted apart (`BLUEPRINT.md` was untouched since July and still advised a parent folder that is not a repo, `git add -A` and promotion through the Coolify UI); keeping both was rejected as two copies of one rule set, and moving the blueprint back into git was not re-opened.
[2026-09-11] monorepo: `set_staging_version_forced.sh` warns (a `::warning::` annotation) when the staging app has a webhook deployment from the last 30 minutes, and still deploys (#58) — refusing like `promote_forced.sh` was rejected because on staging the stamped deploy is the cure for the race, so refusing would leave the unstamped webhook build as the only one; the 30-minute window rather than any webhook deployment in the list, because the list keeps webhook builds from before auto-deploy was switched off.
[2026-09-11] monorepo: `set_staging_version_forced.sh` stamps `SENTRY_RELEASE` only where the staging app already has the variable, warning otherwise, and never for fantasy-web, whose release comes from `APP_VERSION` (#61) — creating it from the script was rejected because it widens six CI keys from updating values to adding variables with flags the script must guess (and Coolify adds a preview copy); failing was rejected because no staging app has the variable yet, so every repo's merge would go red at once.
[2026-09-13] monorepo: the four Spring services run the unpacked boot jar (`java -Djarmode=tools -jar app.jar extract` in each Dockerfile; bff#233, db#115, yahoo#54, espn#28) instead of the nested one — staging's BFF deadlocked on 2026-09-11 with both of the 2-core box's virtual-thread carriers pinned in class loading behind a lock in Spring Boot's `NestedJarFile`, and stopped answering everything, health check included; raising `jdk.virtualThreadScheduler.parallelism` was rejected as making the deadlock rarer rather than impossible, and turning virtual threads off as against the services' concurrency model.
