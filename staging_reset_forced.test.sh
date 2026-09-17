#!/usr/bin/env bash
# Exercise staging_reset_forced.sh against a stubbed docker: which modes it accepts, that the SQL
# reaches psql only after a backup was written, and that a failed dump stops it before the SQL.
#
#   ./staging_reset_forced.test.sh
#
# The nightly workflow runs this before it touches staging; run it by hand after editing the script.
set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/staging_reset_forced.sh"
FAILS=0
check() { # <description> <condition...>
  local what="$1"; shift
  if "$@"; then echo "ok   - $what"; else echo "FAIL - $what"; FAILS=$((FAILS + 1)); fi
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"

# docker ps answers with a container only for db-service's name; `docker exec` records what it
# ran, fails a pg_dump when DUMP_FAILS is set, and echoes stdin back for psql.
cat > "$WORK/bin/docker" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  ps)
    [[ "$*" == *"name=^tfe2vqjob3nplmppicy37bgu"* ]] && echo abc123
    ;;
  exec)
    if [[ "$*" == *pg_dump* ]]; then
      echo "dump $*" >> "$CALLS"
      [ -n "${DUMP_FAILS:-}" ] && exit 1
      echo "-- data"
    else
      echo "psql $*" >> "$CALLS"
      cat
    fi
    ;;
esac
STUB
chmod +x "$WORK/bin/docker"

run() { # <mode> <stdin>
  CALLS="$WORK/calls" PATH="$WORK/bin:$PATH" STAGING_RESET_BACKUP_DIR="$WORK/backups" \
    SSH_ORIGINAL_COMMAND="$1" bash "$SCRIPT" <<<"$2" >"$WORK/out" 2>"$WORK/err"
}

run "rm -rf /" "SELECT 1;"
check "refuses a command that is not a database" [ $? -ne 0 ]
check "and says why" grep -q "refused: expected" "$WORK/err"

run "db; id" "SELECT 1;"
check "refuses a database name with anything appended" [ $? -ne 0 ]

rm -f "$WORK/calls"
run yahoo "SELECT 1;"
check "refuses when the database container is not running" [ $? -ne 0 ]
check "and runs nothing in that case" [ ! -e "$WORK/calls" ]

rm -f "$WORK/calls"
run db "SELECT 'reset';"
check "runs db-service's reset" [ $? -eq 0 ]
check "hands the SQL to psql and prints its output" grep -q "SELECT 'reset';" "$WORK/out"
check "dumps before it runs the SQL" [ "$(cut -d' ' -f1 "$WORK/calls" | tr '\n' ' ')" = "dump psql " ]
check "leaves a backup behind" compgen -G "$WORK/backups/*-db.sql.gz" >/dev/null
check "runs psql in one transaction that stops on the first error" \
  grep -q "ON_ERROR_STOP=1 --single-transaction -f -" "$WORK/calls"

rm -f "$WORK/calls" "$WORK/backups"/*
DUMP_FAILS=1 run db "SELECT 'reset';"
check "fails when the backup cannot be taken" [ $? -ne 0 ]
check "and never reaches psql" [ "$(grep -c '^psql' "$WORK/calls")" -eq 0 ]
check "and leaves nothing behind in the backup folder" [ -z "$(ls -A "$WORK/backups")" ]

rm -f "$WORK/backups"/*
for i in $(seq -w 1 16); do touch -d "2026-01-$i" "$WORK/backups/202601${i}T000000Z-db.sql.gz"; done
touch "$WORK/backups/20260101T000000Z-espn.sql.gz"
run db "SELECT 1;"
check "keeps the newest 14 backups of a database" [ "$(ls "$WORK/backups"/*-db.sql.gz | wc -l)" -eq 14 ]
check "without pruning another database's" [ -e "$WORK/backups/20260101T000000Z-espn.sql.gz" ]

[ "$FAILS" -eq 0 ] && echo "all passed" || { echo "$FAILS failed"; exit 1; }
