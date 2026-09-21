---
name: copy-check
description: Review every user-facing string a change adds or edits, as its own pass, before the PR is opened. Use after finishing work in the fantasy monorepo that touched any text a SlapStat user reads (a button, a heading, a tooltip, an error, an empty state, a banner, a dialog, an email, a meta tag), and whenever Alexander asks to review the copy in a branch, a diff or a PR. Also use when a PR is open and its copy has not been read as copy. This is the review counterpart to the slapstat-copy skill, which is for writing; run this one on the finished diff.
disable-model-invocation: true
---

# Copy check

Review every user-facing string added or changed in a SlapStat change as a dedicated copy pass.

Use this after finishing work in the fantasy monorepo that changed text a user can read, including buttons, headings, labels, tooltips, errors, empty states, banners, dialogs, emails and metadata.

This is the review counterpart to `slapstat-copy`:
- `slapstat-copy` helps write copy.
- `copy-check` reviews the finished change.

## 1. Get the strings

Start from the changed files and inspect every user-facing string:

```bash
git diff origin/master...HEAD -- 'src/app/**/*.html' 'src/app/**/*.ts' 'src/index.html'
```

Review:

- visible template text
- `appTooltip`
- `aria-label`
- `placeholder`
- `title`
- `alt`
- user-facing string literals in matching `.ts` files
- `<title>`, `meta[name=description]`, `og:*` and `twitter:*` metadata

Ignore code that users never see, such as CSS classes, routes and test IDs.

If the change contains no new or changed user-facing copy, say so and stop.

## 2. Run the mechanical check

```bash
cd fantasy-web && npm run check:copy
```

This catches machine-checkable issues such as:

- terminology drift
- banned phrases
- brand casing
- punctuation (em dashes)

Fix reported violations before doing the editorial review.

If a rule looks wrong for the context, flag the rule rather than rewriting good copy to work around it.

## 3. Read the relevant references

Before judging the strings, read:

- `slapstat-copy/references/patterns.md`
- `slapstat-copy/references/terminology.md`
- `fantasy-web/COPY-RULES.md`

Read the relevant sections rather than treating the files as a checklist.

- `patterns.md` shows what good SlapStat copy looks like.
- `terminology.md` defines product vocabulary.
- `COPY-RULES.md` contains the mechanically enforced rules.

## 4. Review every string

Give every changed string exactly one verdict:

1. Keep — already right.
2. Small edit — one word or clause.
3. Rewrite — the wording or structure needs to change.
4. Remove — the string does not need to exist.

Do not rewrite good copy to demonstrate effort.

Prefer Remove when a sentence:

- repeats the previous sentence
- explains an obvious consequence
- adds generic reassurance
- defends or promotes the product without adding information

The best revision is sometimes no sentence at all.

### Review for

#### Clarity

- Is the meaning immediately clear?
- Does the wording match what the UI actually does?

#### Concision

- Can anything be removed without losing useful information?
- Is the sentence explaining something the user already knows?

#### Natural language

- Does it sound like normal English?
- Does it avoid generic AI/SaaS phrasing?

#### SlapStat voice

- Direct, specific and confident.
- No unnecessary enthusiasm, jokes or marketing language.
- Use fantasy hockey terminology naturally.

#### Context

- Does the string make sense where it appears?
- Does it repeat a nearby heading, label or value?
- Does a tooltip explain something the user cannot infer?

## 5. Check product accuracy

Preserve what the application actually does.

Do not:

- invent behaviour
- add guarantees
- remove important limitations
- call something automatic, instant, secure, private or refundable unless supported
- invent legal claims

If the copy depends on a product fact you cannot verify, flag it instead of guessing.

## 6. Render when context matters

For UI copy whose meaning depends on its surroundings, inspect the rendered screen.

Pay particular attention to:

- buttons beside other buttons
- tooltips beside headings or controls
- empty states
- banners
- validation messages
- dialogs
- copy that may wrap or duplicate nearby text

You do not need to render metadata or other copy with no meaningful visual context.

## 7. Report

For every string that is not Keep, report:

```
src/app/example/example.html:42

Now:
Unlock the full power of your projections

→
See every player ranked to your league

Reason:
"Full power" is vague and adds no useful information.
```

Keep reasons brief. Explain the reasoning only when the change is not obvious.

Give at most two variants when there is a genuine judgement call. Prefer making a decision.

Finish with totals:

```
11 strings reviewed
7 kept
2 small edits
1 rewrite
1 removed
```

Then state whether anything remains unresolved:

- an unverified product fact
- a questionable CI rule
- a string whose context could not be inspected
