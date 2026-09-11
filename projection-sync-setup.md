# Projection sync: install on a server

`projection-sync.sh` keeps fantasy-projection-service's store current every night (rosters,
ingest, injuries, lines, re-projection). Nothing in Coolify or the service schedules it, and
nothing deploys the files: they are copied onto each server by hand, so **a change merged here is
not live on a server until someone installs it there.**

The script, the service and the timer are the same files on both servers. The script finds its
container by the Coolify label `coolify.serviceName` ending in `-projection-service`
(`staging-projection-service`, `prod-projection-service`), so there is nothing to edit per host.

| Server | IP | Installed |
|---|---|---|
| staging | `62.238.17.178` | yes, since August 2026; last copied 2026-09-11 from workspace #48, which predates the label lookup |
| production | `157.180.126.72` | **no** (as of 2026-09-11) |

Update this table when either changes. Everything below runs from Git Bash on your machine,
from any checkout of this repo, after `git fetch origin`. `HOST` is the server's IP.

## 0. Production only: prerequisites

The sync runs whatever `projection` CLI the container has, against whatever schema its store
has. Production's projection-service is far behind master, so first:

1. **Promote `prod-projection-service` to the current release.** Publish the newest draft
   release of `fantasy-projection-service` on GitHub (that runs `promote-to-prod.yml`). The
   container runs `alembic upgrade head` on start, so this is also the schema migration of the
   production store, in one step, across every release since the last promotion.
2. **Confirm it landed.** A deploy whose health check fails rolls back without a word, and the
   release list still says *Latest*. Read the running container instead:
   ```
   ssh root@157.180.126.72 'for c in $(docker ps --format "{{.Names}}"); do n=$(docker inspect $c --format "{{index .Config.Labels \"coolify.serviceName\"}}"); v=$(docker inspect $c --format "{{range .Config.Env}}{{println .}}{{end}}" | grep -E "^APP_VERSION"); echo "$n :: $v"; done' | grep projection
   ```
   `prod-projection-service :: APP_VERSION=` must show the version you just published.
3. **Check the store has history to project from.** The nightly run ingests **one** season, the
   one with games in it. The model weights the three seasons before the target (5/4/3) and reads
   per-game logs for them, so a store without those gets a projection out of nothing, and the run
   still reports success. Read-only:
   ```
   printf '%s\n' 'select season, count(*) from skater_season group by season order by season;' 'select season, count(*) from skater_game group by season order by season;' \
     | ssh root@157.180.126.72 'docker exec -i $(docker ps -q --filter name=^iqxk0i5swnh8ga31lf7f45zp | head -1) sh -c "psql -U \$POSTGRES_USER -d \$POSTGRES_DB"'
   ```
   (`iqxk0i5swnh8ga31lf7f45zp` is production's projection-postgres, the same form as *Reaching a
   database* in `INFRASTRUCTURE.md` §8.) If the target season is 2026, seasons 2023, 2024 and 2025
   must each have rows in both tables. If they do not, backfill by hand **before** enabling the
   timer, detached so a dropped SSH session does not kill it, and outside the unit's 90-minute cap:
   ```
   ssh root@157.180.126.72 'systemd-run --unit=projection-backfill --collect sh -c "docker exec \$(docker ps -q --filter label=coolify.serviceName=prod-projection-service --filter health=healthy | head -1) projection ingest --from 2023 --to 2025 && docker exec \$(docker ps -q --filter label=coolify.serviceName=prod-projection-service --filter health=healthy | head -1) projection game-logs --from 2023 --to 2025"'
   ssh root@157.180.126.72 'journalctl -u projection-backfill -f'
   ```
   It ends with an `Ingested seasons` line and then a `Game logs for` line. A deploy of
   projection-service while it runs kills it; start it again.
4. **The BFF must ask for the season the sync projects.** The script projects the calendar year
   from July (the year before until then). Production's BFF `PROJECTION_SEASON` has to say the
   same, or the API answers 200 with an empty list. None of this switches the model on for users:
   that is `PROJECTION_MODEL_ENABLED` on the BFF, a separate decision.
5. **Sentry and the environment name.** The script reports failures with the health monitor's
   files. Check both exist and are what the monitor on that host uses:
   ```
   ssh root@157.180.126.72 'cat /root/.health-env; test -s /root/.health-dsn && echo "dsn present" || echo "NO DSN FILE"'
   ```
   Without `/root/.health-dsn` the script still runs, but every failure goes only to the journal
   (it logs a warning saying so). The health monitor copes without the file by borrowing a DSN from
   a container; the sync does not.

## 1. Copy the three files from master

Straight from the `origin/master` blob, so a working copy on another branch or with CRLF endings
cannot leak across. Keep the old script if there is one.

```
HOST=157.180.126.72
ssh root@$HOST 'test -f /root/projection-sync.sh && cp /root/projection-sync.sh /root/projection-sync.sh.bak-$(date +%F); true'
MSYS_NO_PATHCONV=1 git show origin/master:projection-sync.sh      | ssh root@$HOST 'cat > /root/projection-sync.sh && chmod 700 /root/projection-sync.sh'
MSYS_NO_PATHCONV=1 git show origin/master:projection-sync.service | ssh root@$HOST 'cat > /etc/systemd/system/projection-sync.service'
MSYS_NO_PATHCONV=1 git show origin/master:projection-sync.timer   | ssh root@$HOST 'cat > /etc/systemd/system/projection-sync.timer'
```

## 2. Compare checksums against master

```
for f in projection-sync.sh projection-sync.service projection-sync.timer; do MSYS_NO_PATHCONV=1 git show origin/master:$f | sha256sum; done
ssh root@$HOST 'sha256sum /root/projection-sync.sh /etc/systemd/system/projection-sync.service /etc/systemd/system/projection-sync.timer'
```

The three hashes must match pairwise. Do not go on if one does not.

## 3. Check it finds the right container, before it runs anything

```
ssh root@$HOST '/root/projection-sync.sh --find-container'
```

It prints the service name and container id and runs nothing. On production that must be
`prod-projection-service <id>`, on staging `staging-projection-service <id>`. Anything else (no
container, or two services named like it) exits 1 with the reason, and the timer would fail the
same way every night.

## 4. Enable the timer

```
ssh root@$HOST 'systemctl daemon-reload && systemctl enable --now projection-sync.timer'
```

On staging, where the timer is already enabled, `daemon-reload` alone picks up changed units;
`enable --now` is harmless there.

## 5. See it fire

The next firing time, and the last:
```
ssh root@$HOST 'systemctl list-timers projection-sync.timer'
```

To prove the script now rather than tomorrow, start one run off-schedule (the timer still fires
on its own at 04:30 UTC, plus up to 15 minutes):
```
ssh root@$HOST 'systemctl start --no-block projection-sync.service'
ssh root@$HOST 'journalctl -u projection-sync.service -f'
```

A good run logs, in order, a `Swept`, an `Ingested seasons`, an `ESPN reports`, a `Read` and a
`Projected` line, and the unit ends with `status=0/SUCCESS`:
```
ssh root@$HOST 'systemctl status projection-sync.service --no-pager | head -5; journalctl -u projection-sync.service -n 60 --no-pager | grep -E "FAILED|WARNING|Swept|Ingested|ESPN reports|Read |Projected"'
```

**A manual start is not the timer.** The job is running only once the journal shows a run that
started at 04:30 to 04:45 UTC on its own. Look the morning after, and update the table at the top.
