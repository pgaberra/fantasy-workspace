# Calibration

A fixed set of 20 SlapStat copy cases used to calibrate `slapstat-copy`.

Each case has a **Proposed** answer from the skill and a **Yours** field for Alexander's judgment.

## How to use it

1. Fill in **Yours** for every case: `ok`, or the wording you would ship. Add **Why** only when you correct it.
2. When `SKILL.md`, `patterns.md` or `terminology.md` changes, run the same 20 cases again in a fresh session and compare the new answers with **Yours**.
   Give that session only each case's heading, file and quoted string. Never show **Proposed**, **Because**, **Yours** or **Why**: they are the answers.

Before scoring, set aside any case whose **Proposed** or **Yours** wording appears verbatim in `patterns.md`. A session can quote that file instead of judging, so those cases measure nothing in that round. Say which cases were set aside.

Score three things separately:

| Measure | Meaning |
| --- | --- |
| **Verdict** | Keep, small edit, rewrite or remove matches the human judgment. This catches over-editing. |
| **Direction** | The skill makes the same kind of change, even when the wording differs. |
| **Wrong direction** | The skill and the human disagree about the actual change needed. |

The most important measure is **wrong direction**. Different wording is normal; a different judgment is the signal.

Some cases are deliberately proposed as **keep** or **remove**. Rewriting those in later rounds is a warning that the skill is editing good copy for its own sake.

## Keep the benchmark fixed

- Do not add cases just because the skill missed them.
- The set was fixed on 2026-09-10, after eleven cases whose answers `patterns.md` already gave were replaced.
- Do not rewrite a recorded proposal after the fact.
- Do not copy calibration cases verbatim into `patterns.md`. Extract the lesson and create a separate example.
- Keep the set small enough to rerun regularly.

A case remains useful even if the original string later changes in the app. The benchmark is testing the judgment, not the current line number.

## Why the proposed answers exist

The proposed answer makes calibration cheap: the human only needs to agree or correct. **Yours** is the ground truth for the preference this skill is trying to learn.

The purpose is not to make the skill reproduce exact wording. It is to make its judgment converge toward the human judgment encoded in the corrections.

## Case 6

Case 6 is intentionally unresolved. The proposed edit exposes a product fact that the copy review could not verify. The correct behaviour is to flag the missing fact rather than invent it.

If that fact is later documented in the skill, re-run case 6 first.
