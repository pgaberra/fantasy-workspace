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
