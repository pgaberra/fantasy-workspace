# Staging reset — setup and restore

Every night at 05:00 UTC the **"Staging reset"** workflow in this repo puts staging's user data
back to a fixed baseline, an hour before the E2E suite runs against it. It closes
pgaberra/fantasy-db-service#45.

## What the baseline is

| Account | Password from secret | What it holds after a reset |
|---|---|---|
| `premium-test@slapstat.com` (username `premium_tester`) | `STAGING_PREMIUM_PASSWORD` | Premium (an admin grant, no subscription), "Category league" and "Points league" projections, and a Last Season's Stats draft set up for 12 teams with no picks |
| `free-test@slapstat.com` (username `free_tester`) | `STAGING_FREE_PASSWORD` | No Premium, one "Points league" projection |
| the E2E account (`E2E_EMAIL`) | `E2E_PASSWORD` | Nothing, like a fresh sign-up; the E2E specs expect that |
| the admin account (`STAGING_ADMIN_EMAIL`) | its own | **Untouched**: projections, Premium, Yahoo link and ESPN cookies all stay. Admin rights come from `ADMIN_EMAILS` on staging's BFF, not from here |

These four are the only accounts on staging after a reset: an account made for anything else is
gone the next morning. The admin account is kept rather than recreated, because its Yahoo link is
stored against its id and would not survive a new one; if it does not exist, the run warns and
carries on, and signing up with that address once brings it back for good. The three seeded
accounts are recreated from scratch every night, with the same ids, verified emails and passwords
set from the secrets, so whatever was done to them during the day is gone too, a changed password
included.

Every other account is deleted along with everything it owned, in db-service (projections, shares,
subscriptions, pending checkouts, grants, avatars, tokens), yahoo-service (OAuth tokens and pending
flows) and espn-service (cookies). Yahoo's `__service__` row, the admin's Yahoo link, is always
kept. Player data in every service, and the projection store as a whole, are not touched.

The projections come from `staging-reset/fixtures/`: gzipped copies of real staging boards from
2026-09-17 (season 20262027, Yahoo player ids). To refresh them, export a projection's `data` from
staging and write it in the same `{"season", "playerIdSpace", "data"}` shape.

## One-time setup

### 1. Restricted SSH key

```bash
ssh-keygen -t ed25519 -N '' -f ./staging-reset-key -C 'staging-reset'
gh secret set STAGING_RESET_SSH_KEY --repo pgaberra/fantasy-workspace < ./staging-reset-key
```

The public half goes on the **staging** server (`62.238.17.178`), one line in
`/root/.ssh/authorized_keys`:

```
command="/root/staging_reset_forced.sh",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty ssh-ed25519 AAAA...staging-reset
```

Then delete both halves locally.

**What the key can do:** run any SQL it is sent against staging's db-, yahoo- and espn-service
databases, after a backup. The reset logic lives in `staging_reset.py`, so it can change without a
reinstall on the server. The key cannot reach the projection store, production, or a shell.

### 2. Install the forced command on the staging server

Copy the `origin/master` blob of `staging_reset_forced.sh` to `/root/staging_reset_forced.sh`, check
its sha256 against `git show origin/master:staging_reset_forced.sh | sha256sum`, and `chmod 700` it.

### 3. Secrets in `pgaberra/fantasy-workspace`

| Secret | Value |
|---|---|
| `STAGING_RESET_SSH_KEY` | step 1 |
| `STAGING_PREMIUM_PASSWORD`, `STAGING_FREE_PASSWORD` | new passwords, kept in your password manager |
| `E2E_EMAIL`, `E2E_PASSWORD` | the same values as in `fantasy-web`, or the E2E sign-in breaks the morning after |
| `STAGING_ADMIN_EMAIL` | the admin account's address, kept out of the code because the repo is public |

The run refuses to start while any of these is empty.

### 4. First run

Dispatch **Actions → Staging reset → Run workflow**, then check that:

- the run is green and prints `deleted N, admin kept 1, 3 seeded`;
- you can sign in to staging as both test accounts, and the premium account shows Premium;
- the E2E run at 06:00 the next morning is green.

It is not live until the 05:00 schedule has been seen firing.

## When a run fails

The `report` job opens a `staging-reset-red` issue here, adds a comment to it for each further
failure, and closes it on the next green run. Each database step is one transaction, so the step
that failed changed nothing. The steps run in the order db → yahoo → espn. If a later step fails,
the Yahoo or ESPN rows of accounts already deleted are left behind with no user to point at, and
the next green run removes them.

The usual reason for a failure is a new table that holds user data. If its foreign key to `users`
does not cascade, the delete fails in the `test` job, before staging is touched. Add the table to
`db_sql` (or `yahoo_sql` / `espn_sql`) in `staging_reset.py`. A per-user table in another service
never fails the run; it just keeps its rows until someone adds it.

## Restoring a backup

Before each step the server writes a data-only dump of that database's user tables to
`/root/staging-reset-backups/<UTC stamp>-<db|yahoo|espn>.sql.gz`. The newest 14 of each are kept.
To put db-service back to the state before a reset:

```bash
C=$(docker ps -q --filter name=^tfe2vqjob3nplmppicy37bgu | head -1)
{ echo 'BEGIN; TRUNCATE users, user_projections, projection_shares, password_reset_tokens,
    email_verification_tokens, subscriptions, pending_checkouts, premium_grants, user_avatars;';
  gunzip -c /root/staging-reset-backups/<stamp>-db.sql.gz; echo 'COMMIT;'; } |
  docker exec -i "$C" sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1'
```

For yahoo and espn, truncate only the tables named in `staging_reset_forced.sh` for that database.
Restore all three from the same night, so the Yahoo and ESPN rows match the users they belong to.
