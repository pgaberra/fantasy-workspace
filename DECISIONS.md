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
[2026-09-11] monorepo: a failed promotion opens a `prod-promotion-failed` issue in its own repo, from six identical copies of `promote-to-prod.yml` rather than one reusable workflow here (fantasy-workspace#30) — the repos are private with Actions access set to none, so sharing needs a settings change in all seven, and it would put every prod deploy behind this repo's master; one issue in this repo was rejected because the default token cannot write across repos and a PAT is one more secret.
[2026-09-11] monorepo: `projection-sync.sh` runs `projection game-logs` (the season with games) and `projection schedule` (the season projected) only in season, October to June, when the two are the same season (WS_PR, PS_PR) — the logs feed Who's hot and the schedule is what a return date is counted on, since a season's logs stop at last night; out of season the run is left as it was, as asked, which keeps today's offseason projection counting February 2027 return dates on 2025-26's Olympic break until 1 October — running the schedule step year-round fixes that too and is a one-line change, left for Alexander because it moves a number users already see; year-round game logs were rejected as a nightly re-fetch of a finished season.
