#!/usr/bin/env bash
# Restricted forced-command for the "staging reset" SSH key (mirrors staging_access_forced.sh).
#
# Install on the STAGING server (62.238.17.178) as /root/staging_reset_forced.sh, chmod 700. The
# matching public key goes in /root/.ssh/authorized_keys pinned to this command (one line):
#
#   command="/root/staging_reset_forced.sh",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty ssh-ed25519 AAAA... staging-reset
#
# Invoked by the "Staging reset" workflow as:
#   ssh root@62.238.17.178 db    < reset.sql   ->  fantasy-db-service's database
#   ssh root@62.238.17.178 yahoo < reset.sql   ->  fantasy-yahoo-service's database
#   ssh root@62.238.17.178 espn  < reset.sql   ->  fantasy-espn-service's database
#
# It backs up that database's user tables, then runs the SQL on stdin in one transaction and prints
# its rows. What the SQL does lives in staging-reset/staging_reset.py, so changing the reset needs
# no reinstall here; the price is that this key can run any SQL on those three staging databases.
# It cannot reach the projection store, production, or anything else on the box.
#
# Backups: /root/staging-reset-backups/<UTC stamp>-<db>.sql.gz, data only, newest KEEP_BACKUPS
# per database kept. Restoring one is in staging-reset-setup.md.
set -euo pipefail

BACKUP_DIR="${STAGING_RESET_BACKUP_DIR:-/root/staging-reset-backups}"
KEEP_BACKUPS=14

MODE="${SSH_ORIGINAL_COMMAND:-}"
case "$MODE" in
  # Coolify's container name prefixes (INFRASTRUCTURE.md, "Reaching a database"). Every table in
  # db-service holds user data; the other two hold shared player data that is not backed up.
  db)
    NAME=tfe2vqjob3nplmppicy37bgu
    DUMP_ARGS=(-T flyway_schema_history)
    ;;
  yahoo)
    NAME=wn3g7ygq9mfxmno9bsfsnqtu
    DUMP_ARGS=(-t yahoo_oauth_tokens -t yahoo_oauth_pending_states -t yahoo_oauth_pending_links)
    ;;
  espn)
    NAME=nj5pnanlz5efnlj5q65uposk
    DUMP_ARGS=(-t espn_credentials)
    ;;
  *)
    echo "refused: expected 'db', 'yahoo' or 'espn', got '$MODE'" >&2
    exit 1
    ;;
esac

CONTAINER="$(docker ps -q --filter "name=^$NAME" | head -1)"
if [ -z "$CONTAINER" ]; then
  echo "refused: no running database container for $MODE" >&2
  exit 1
fi

# No reset without its backup: a failed dump stops here, before the SQL is read. Written under a
# temporary name so a half-written file is never mistaken for a backup.
umask 077
mkdir -p "$BACKUP_DIR"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
PARTIAL="$BACKUP_DIR/.$STAMP-$MODE.partial"
trap 'rm -f "$PARTIAL"' EXIT
docker exec "$CONTAINER" sh -c 'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" --data-only "$@"' \
  sh "${DUMP_ARGS[@]}" </dev/null | gzip > "$PARTIAL"
mv "$PARTIAL" "$BACKUP_DIR/$STAMP-$MODE.sql.gz"
trap - EXIT
ls -1t "$BACKUP_DIR"/*-"$MODE".sql.gz | tail -n +$((KEEP_BACKUPS + 1)) | xargs -r rm --

# The same psql flags test_staging_reset.py runs the SQL with.
exec docker exec -i "$CONTAINER" sh -c \
  'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -X -q -At -v ON_ERROR_STOP=1 --single-transaction -f -'
