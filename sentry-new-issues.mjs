#!/usr/bin/env node
//
// Every Sentry issue first seen since a watermark, routed to the repo that owns it.
//
// This is the deterministic half of the triage round. It answers "what is new" with no model in
// the loop, which matters for two reasons: routing is a lookup rather than a judgement and
// should not cost a token, and a scheduled round has to be checkable on its own. A job whose
// only output is a model's prose cannot be verified; this one can be run by hand and read.
//
// Routing is NOT one project per service. The `slapstat` org has exactly two projects:
//
//   fantasy-web        the Angular front end. One repo, no ambiguity.
//   java-spring-boot   ALL FOUR Spring services, under the default name the setup wizard gave
//                      it. They are told apart by the culprit's base package, which is distinct
//                      per service (com.fantasy.bff / .db / .yahoo / .espn).
//
// That sharing is a defect in its own right rather than a design: it makes per-service alert
// rules impossible, and it puts four independently deployed services in one release namespace,
// so "which release introduced this" has no answer there.
//
// projection-service has no Sentry project at all, so nothing it does can appear here yet.
//
// Usage:
//   SENTRY_AUTH_TOKEN=… node sentry-new-issues.mjs --since 2026-09-01T00:00:00Z [--json]
//
// Exits non-zero on any failure to reach Sentry. That is deliberate: an empty result and a
// failed request look identical downstream, and "nothing is broken" is the most expensive
// wrong answer this script could give.

const ORG = 'slapstat';
// The org lives in Sentry's EU region. Overridable so the parsing and routing can be exercised
// against a canned response in a test.
const API = process.env.SENTRY_API_BASE ?? 'https://de.sentry.io/api/0';
const PROJECTS = ['fantasy-web', 'java-spring-boot'];

// Longest prefix wins. The packages do not nest, so the order is irrelevant.
const PACKAGE_ROUTES = [
  ['com.fantasy.bff', 'pgaberra/fantasy-bff'],
  ['com.fantasy.db', 'pgaberra/fantasy-db-service'],
  ['com.fantasy.yahoo', 'pgaberra/fantasy-yahoo-service'],
  ['com.fantasy.espn', 'pgaberra/fantasy-espn-service'],
];

/** The repo that owns an issue, or UNROUTED when the culprit names no service of ours. */
export function routeIssue(project, culprit = '') {
  if (project === 'fantasy-web') return 'pgaberra/fantasy-web';
  for (const [prefix, repo] of PACKAGE_ROUTES) {
    if (culprit.startsWith(prefix)) return repo;
  }
  // Reported as unplaced rather than guessed at. A wrong repo is worse than no repo, because
  // nobody who could act on it will ever look there.
  return 'UNROUTED';
}

function parseArgs(argv) {
  const args = { since: null, json: false };
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--since') args.since = argv[++i];
    else if (argv[i] === '--json') args.json = true;
    else throw new Error(`unknown argument: ${argv[i]}`);
  }
  if (!args.since) throw new Error('usage: sentry-new-issues.mjs --since <ISO8601> [--json]');
  return args;
}

async function fetchProjectIssues(project, since, token) {
  // `firstSeen` rather than `lastSeen`: the round is about what is NEW. A long-standing issue
  // that fired again today has been triaged once already, and re-filing it is exactly the
  // thrash the fingerprint rule exists to prevent.
  const query = `is:unresolved firstSeen:>${since}`;
  const url = `${API}/projects/${ORG}/${project}/issues/?query=${encodeURIComponent(query)}&statsPeriod=90d&limit=100`;
  const response = await fetch(url, { headers: { Authorization: `Bearer ${token}` } });
  if (!response.ok) {
    throw new Error(
      `Sentry returned ${response.status} for project ${project}. Treating this as a failure ` +
        `rather than an empty result: a 401 here would otherwise read as "nothing is broken".`,
    );
  }
  const issues = await response.json();
  return issues.map((issue) => ({
    shortId: issue.shortId,
    project,
    repo: routeIssue(project, issue.culprit ?? ''),
    title: issue.title,
    culprit: issue.culprit ?? '',
    // Sentry sends the event count as a string.
    events: Number(issue.count ?? 0),
    users: issue.userCount ?? 0,
    level: issue.level ?? 'error',
    firstSeen: issue.firstSeen,
    lastSeen: issue.lastSeen,
    permalink: issue.permalink,
  }));
}

export async function collect(since, token) {
  const perProject = await Promise.all(PROJECTS.map((p) => fetchProjectIssues(p, since, token)));
  // Busiest first: the round has a cap, and if it has to stop early it should stop on the ones
  // that matter least.
  return perProject.flat().sort((a, b) => b.events - a.events);
}

function render(issues, since) {
  const lines = [`Sentry issues first seen since ${since}: ${issues.length}`];
  if (issues.length === 0) return lines.join('\n');

  const pad = (s, n) => String(s).padEnd(n);
  lines.push('');
  lines.push(
    `${pad('SHORT ID', 24)} ${pad('REPO', 24)} ${pad('EVENTS', 7)} ${pad('LEVEL', 8)} TITLE`,
  );
  for (const i of issues) {
    lines.push(
      `${pad(i.shortId, 24)} ${pad(i.repo.replace('pgaberra/', ''), 24)} ` +
        `${pad(i.events, 7)} ${pad(i.level, 8)} ${i.title.slice(0, 70)}`,
    );
  }

  const unrouted = issues.filter((i) => i.repo === 'UNROUTED');
  if (unrouted.length > 0) {
    lines.push('');
    lines.push(
      `${unrouted.length} issue(s) could not be routed. Their culprit matched no base package ` +
        `of ours: either a new service reports here, or the culprit is a framework frame. ` +
        `They need a human to place them.`,
    );
  }
  return lines.join('\n');
}

// Only run when invoked directly, so the routing can be imported by a test.
if (import.meta.url === `file://${process.argv[1]}` || process.argv[1]?.endsWith('sentry-new-issues.mjs')) {
  const token = process.env.SENTRY_AUTH_TOKEN;
  if (!token) {
    console.error(
      '::error::SENTRY_AUTH_TOKEN is not set. Without it this would report zero new issues, ' +
        'which is indistinguishable from a quiet day, so it fails instead.',
    );
    process.exit(1);
  }
  try {
    const { since, json } = parseArgs(process.argv.slice(2));
    const issues = await collect(since, token);
    console.log(json ? JSON.stringify({ since, count: issues.length, issues }, null, 2) : render(issues, since));
  } catch (error) {
    console.error(`::error::${error.message}`);
    process.exit(1);
  }
}
