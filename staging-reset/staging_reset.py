"""Put staging's user data back to a fixed baseline: three seeded accounts plus a short keep-list.

Run nightly by the "Staging reset" workflow (.github/workflows/staging-reset.yml); setup and restore
steps are in staging-reset-setup.md. Everything else a tester, an E2E run or an agent left behind
on staging goes: accounts, their projections, shares, subscriptions, Yahoo links and ESPN cookies.
The player data every service holds is shared, not per user, and is not touched.

The seed is written straight to the tables rather than signed up through the BFF, so no
verification mail goes out to an address nobody reads and the seed does not depend on the sign-up
flow working. The price is that a new table holding user data has to be known here: one whose
foreign key does not cascade stops the delete, which fails the run loudly (the intended outcome),
and one keyed by an app user id in another service is simply left alone until it is added below.

Three databases, three transactions, run in order: db-service first, since it decides which user
ids survive; then yahoo- and espn-service drop every row whose user is no longer one of them. If a
later step fails, its rows are orphans that name no user, and the next run removes them.
"""

from __future__ import annotations

import gzip
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

FIXTURES = Path(__file__).parent / "fixtures"

# The row yahoo-service keeps for the admin's own Yahoo link, which the league-wide player
# position fetch signs in with. It is nobody's account and must survive every reset.
YAHOO_SERVICE_ACCOUNT = "__service__"

# Fixed ids, so a seeded account is the same account from one night to the next.
PREMIUM_ID = "5eed0000-0000-4000-8000-000000000001"
FREE_ID = "5eed0000-0000-4000-8000-000000000002"
E2E_ID = "5eed0000-0000-4000-8000-000000000003"

UUID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")


@dataclass(frozen=True)
class SeedProjection:
    name: str
    fixture: str
    kind: str = "PROJECTION"
    preset: str | None = None


@dataclass(frozen=True)
class SeedUser:
    id: str
    email: str
    password_hash: str
    username: str | None
    premium: bool
    projections: tuple[SeedProjection, ...] = field(default_factory=tuple)


def seed_users(premium_hash: str, free_hash: str, e2e_email: str, e2e_hash: str) -> list[SeedUser]:
    """The baseline. The E2E account starts empty, as its specs expect of a fresh account."""
    return [
        SeedUser(
            id=PREMIUM_ID,
            email="premium-test@slapstat.com",
            password_hash=premium_hash,
            username="premium_tester",
            premium=True,
            projections=(
                SeedProjection("Category league", "category-league.json.gz"),
                SeedProjection("Points league", "points-league-with-draft.json.gz"),
                # A draft set up for twelve teams with no picks made, so a draft can be resumed.
                SeedProjection(
                    "Last Season's Stats",
                    "points-league-with-draft.json.gz",
                    kind="PRESET_DRAFT",
                    preset="LAST_SEASON",
                ),
            ),
        ),
        SeedUser(
            id=FREE_ID,
            email="free-test@slapstat.com",
            password_hash=free_hash,
            username="free_tester",
            premium=False,
            projections=(SeedProjection("Points league", "points-league-with-draft.json.gz"),),
        ),
        SeedUser(
            id=E2E_ID,
            email=e2e_email,
            password_hash=e2e_hash,
            username=None,
            premium=False,
        ),
    ]


def literal(value: str | None) -> str:
    if value is None:
        return "NULL"
    if "\x00" in value:
        raise ValueError("a value for the reset SQL contains a NUL byte")
    return "'" + value.replace("'", "''") + "'"


def load_fixture(name: str, kind: str) -> tuple[str, str, str]:
    """(season, player id space, data as JSON text). Only a preset draft keeps its draft."""
    with gzip.open(FIXTURES / name, "rt", encoding="utf-8") as f:
        fixture = json.load(f)
    data = fixture["data"]
    if kind != "PRESET_DRAFT":
        data.pop("draft", None)
    return fixture["season"], fixture["playerIdSpace"], json.dumps(data, separators=(",", ":"))


def db_sql(keep_emails: list[str], seeds: list[SeedUser]) -> str:
    """db-service. Prints `deleted <n>`, `kept <n>`, then every surviving user id, one per line."""
    seed_emails = {seed.email.lower() for seed in seeds}
    keep = sorted({email.strip().lower() for email in keep_emails} - seed_emails - {""})
    keep_array = "ARRAY[" + ",".join(literal(e) for e in keep) + "]::text[]"

    lines = [
        # Seeds are always recreated, so a seed address on the keep-list is ignored above.
        "CREATE TEMP TABLE keep_user ON COMMIT DROP AS",
        f"  SELECT id FROM users WHERE lower(email) = ANY ({keep_array})",
        "    AND id NOT IN (" + ",".join(literal(s.id) for s in seeds) + ");",
        # The four tables whose foreign key to users does not cascade go first. A fifth added
        # later makes the delete from users fail, which is the alarm that it has to be listed.
        "DELETE FROM password_reset_tokens WHERE user_id NOT IN (SELECT id FROM keep_user);",
        "DELETE FROM email_verification_tokens WHERE user_id NOT IN (SELECT id FROM keep_user);",
        "DELETE FROM subscriptions WHERE user_id NOT IN (SELECT id FROM keep_user);",
        "DELETE FROM pending_checkouts WHERE user_id NOT IN (SELECT id FROM keep_user);",
        "WITH gone AS (DELETE FROM users WHERE id NOT IN (SELECT id FROM keep_user) RETURNING 1)",
        "  SELECT 'deleted ' || count(*) FROM gone;",
        "SELECT 'kept ' || count(*) FROM keep_user;",
    ]
    for seed in seeds:
        lines.append(
            "INSERT INTO users (id, email, password_hash, created_at, token_version,"
            " email_verified, username) VALUES ("
            f"{literal(seed.id)}, {literal(seed.email)}, {literal(seed.password_hash)}, now(), 0,"
            f" TRUE, {literal(seed.username)});"
        )
        if seed.premium:
            lines.append(
                "INSERT INTO premium_grants (id, user_id, granted_by, reason, starts_at,"
                " expires_at, created_at) VALUES (gen_random_uuid(), "
                f"{literal(seed.id)}, 'staging-reset', 'Seeded premium test account', now(),"
                " now() + INTERVAL '10 years', now());"
            )
        for projection in seed.projections:
            season, id_space, data = load_fixture(projection.fixture, projection.kind)
            lines.append(
                "INSERT INTO user_projections (id, user_id, name, season, data, created_at,"
                " updated_at, kind, preset, player_id_space) VALUES (gen_random_uuid(), "
                f"{literal(seed.id)}, {literal(projection.name)}, {literal(season)},"
                f" {literal(data)}::jsonb, now(), now(), {literal(projection.kind)},"
                f" {literal(projection.preset)}, {literal(id_space)});"
            )
    lines.append("SELECT id FROM users ORDER BY id;")
    return "\n".join(lines) + "\n"


def user_ids_array(user_ids: list[str]) -> str:
    for user_id in user_ids:
        if not UUID.match(user_id):
            raise ValueError("db-service returned something that is not a user id")
    return "ARRAY[" + ",".join(literal(u) for u in [YAHOO_SERVICE_ACCOUNT, *user_ids]) + "]::text[]"


def yahoo_sql(user_ids: list[str]) -> str:
    keep = user_ids_array(user_ids)
    return "".join(
        f"DELETE FROM {table} WHERE app_user_id <> ALL ({keep});\n"
        for table in ("yahoo_oauth_tokens", "yahoo_oauth_pending_states", "yahoo_oauth_pending_links")
    )


def espn_sql(user_ids: list[str]) -> str:
    return f"DELETE FROM espn_credentials WHERE app_user_id <> ALL ({user_ids_array(user_ids)});\n"


def parse_db_output(output: str) -> tuple[list[str], list[str]]:
    """(the summary lines, the surviving user ids)."""
    lines = [line for line in output.splitlines() if line.strip()]
    summary = [line for line in lines if line.startswith(("deleted ", "kept "))]
    ids = [line for line in lines if line not in summary]
    return summary, ids


def hash_password(password: str) -> str:
    import bcrypt  # only the real run needs it; the SQL builders do not

    # Cost 10, the BFF's BCryptPasswordEncoder default; it reads Python's $2b$ prefix as well.
    return bcrypt.hashpw(password.encode("utf-8"), bcrypt.gensalt(10)).decode("ascii")


def ssh_step(mode: str, sql: str) -> str:
    """One database on staging, through the forced command that only runs SQL there."""
    result = subprocess.run(
        [
            "ssh", "-i", os.environ["STAGING_RESET_KEY_FILE"], "-o", "IdentitiesOnly=yes",
            "-o", "BatchMode=yes", "-o", f"UserKnownHostsFile={os.environ['STAGING_KNOWN_HOSTS']}",
            "root@62.238.17.178", mode,
        ],
        input=sql, capture_output=True, text=True, check=False,
    )
    # stderr carries psql's notices and errors, which name tables and constraints, not people.
    sys.stderr.write(result.stderr)
    if result.returncode != 0:
        raise SystemExit(f"the {mode} step failed with exit status {result.returncode}")
    return result.stdout


def require(name: str) -> str:
    value = os.environ.get(name, "")
    if not value.strip():
        raise SystemExit(f"{name} is not set; see staging-reset-setup.md")
    return value


def main() -> None:
    seeds = seed_users(
        premium_hash=hash_password(require("STAGING_PREMIUM_PASSWORD")),
        free_hash=hash_password(require("STAGING_FREE_PASSWORD")),
        e2e_email=require("E2E_EMAIL").strip(),
        e2e_hash=hash_password(require("E2E_PASSWORD")),
    )
    # Required even though an empty list is a valid wish: a secret that went missing must not
    # read as "delete Alexander's own accounts too".
    keep_emails = re.split(r"[,\s]+", require("STAGING_RESET_KEEP_EMAILS"))

    summary, user_ids = parse_db_output(ssh_step("db", db_sql(keep_emails, seeds)))
    # Counts only: the log of a public repo is no place for addresses or account ids.
    print("db-service: " + ", ".join(summary) + f", {len(seeds)} seeded")
    ssh_step("yahoo", yahoo_sql(user_ids))
    print("yahoo-service: per-user rows outside the surviving accounts removed")
    ssh_step("espn", espn_sql(user_ids))
    print("espn-service: per-user rows outside the surviving accounts removed")


if __name__ == "__main__":
    main()
