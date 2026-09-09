#!/usr/bin/env bash
#
# Every Sentry triage run says what it did, on the tracking issue, including the runs that
# failed and the runs that found nothing.
#
# This is the load-bearing part of the whole round. A scheduled job that quietly does nothing
# is indistinguishable from a quiet day, and that is not a hypothetical: three scheduled rounds
# in another codebase fired daily for nineteen days as no-ops because nobody had given them a
# token, and it went unnoticed precisely because a workflow list shows a green tick either way.
# Silence has to be something the round SAYS.
#
# Creates the tracking issue on first use, so setting this up is one less manual step to forget.
set -euo pipefail

: "${GH_TOKEN:?}"
: "${GITHUB_REPOSITORY:?}"
title="${TRACKING_ISSUE_TITLE:-Sentry triage run log}"
outcome="${OUTCOME:-unknown}"
count="${COUNT:-}"
since="${SINCE:-}"
run_started="${RUN_STARTED:-}"
run_url="${RUN_URL:-}"

number=$(gh issue list -R "$GITHUB_REPOSITORY" --state all --limit 100 \
           --search "\"$title\" in:title" --json number,title \
           --jq "[.[] | select(.title == \"$title\")] | first | .number // empty")

if [ -z "$number" ]; then
  number=$(gh issue create -R "$GITHUB_REPOSITORY" --title "$title" --body \
"Where the scheduled Sentry round records what it did. One comment per run, including the runs
that found nothing and the runs that failed, so that a round which has quietly stopped working
is visible here rather than invisible in a list of green ticks.

The newest \`sentry-triage-watermark\` marker in this thread is where the next run starts
reading from. Editing it is the supported way to make a round re-read a period.

Kept open on purpose: closing it does not stop the round, it only hides the log.

See \`.claude/skills/sentry-triage/SKILL.md\` for the contract the round obeys." \
    | sed 's|.*/||')
  echo "Created the tracking issue: #$number"
fi

# A failed run must NOT move the watermark: whatever it did not read has to be read next time.
if [ "$outcome" = "success" ] && [ -n "$run_started" ]; then
  watermark_line="<!-- sentry-triage-watermark: $run_started -->"
  status_line="Read **${count:-0}** issue(s) first seen since \`$since\`."
else
  watermark_line="<!-- watermark deliberately not moved: this run did not finish -->"
  status_line="**Run did not complete** (\`$outcome\`). The watermark stays at \`$since\`, so the
next run re-reads this period. Nothing has been skipped."
fi

gh issue comment "$number" -R "$GITHUB_REPOSITORY" --body \
"<!-- sentry-triage-run: $(date -u +%Y-%m-%dT%H:%M:%SZ) -->
$watermark_line
$status_line

[Run log]($run_url)"

echo "Traced run on issue #$number (outcome: $outcome)."
