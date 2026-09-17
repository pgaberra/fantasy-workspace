"""Runs the reset SQL against real schemas built from each service's own Flyway migrations.

    STAGING_RESET_TEST_PG=postgresql://postgres:postgres@localhost:5432 \
    DB_MIGRATIONS=<fantasy-db-service>/src/main/resources/db/migration \
    YAHOO_MIGRATIONS=<fantasy-yahoo-service>/src/main/resources/db/migration \
    ESPN_MIGRATIONS=<fantasy-espn-service>/src/main/resources/db/migration \
    python -m unittest staging-reset/test_staging_reset.py

The nightly workflow runs this against the services' master before it touches staging, so a
migration that adds a user table with a non-cascading key fails here rather than halfway through
the real reset. Without the variables the database cases are skipped (they say so).
"""

from __future__ import annotations

import os
import re
import subprocess
import unittest
import uuid
from pathlib import Path

import staging_reset as reset

PG = os.environ.get("STAGING_RESET_TEST_PG")
MIGRATIONS = {
    "db": os.environ.get("DB_MIGRATIONS"),
    "yahoo": os.environ.get("YAHOO_MIGRATIONS"),
    "espn": os.environ.get("ESPN_MIGRATIONS"),
}

# The flags staging_reset_forced.sh runs psql with, so the test reads output the way the run does.
PSQL_FLAGS = ["-X", "-q", "-At", "-v", "ON_ERROR_STOP=1", "--single-transaction", "-f", "-"]


def psql(database: str, sql: str) -> str:
    result = subprocess.run(
        ["psql", f"{PG}/{database}", *PSQL_FLAGS],
        input=sql, capture_output=True, text=True, check=False,
    )
    if result.returncode != 0:
        raise AssertionError(f"psql on {database} failed:\n{result.stderr}")
    return result.stdout


def migrate(database: str, directory: str) -> None:
    subprocess.run(
        ["psql", f"{PG}/postgres", "-X", "-q", "-v", "ON_ERROR_STOP=1"],
        input=f"DROP DATABASE IF EXISTS {database}; CREATE DATABASE {database};",
        text=True, check=True, capture_output=True,
    )

    def version(path: Path) -> int:
        return int(re.match(r"V(\d+)__", path.name).group(1))

    for path in sorted(Path(directory).glob("V*__*.sql"), key=version):
        psql(database, path.read_text(encoding="utf-8"))


def seeds(e2e_email: str = "e2e@slapstat.com") -> list[reset.SeedUser]:
    return reset.seed_users("$2b$10$premium", "$2b$10$free", e2e_email, "$2b$10$e2e")


class SqlBuilders(unittest.TestCase):
    def test_quotes_values_it_embeds(self):
        self.assertEqual(reset.literal("O'Reilly"), "'O''Reilly'")
        self.assertEqual(reset.literal(None), "NULL")

    def test_refuses_an_id_list_that_is_not_ids(self):
        with self.assertRaises(ValueError):
            reset.yahoo_sql(["1'); DROP TABLE skaters; --"])

    def test_splits_the_summary_from_the_ids(self):
        summary, ids = reset.parse_db_output("deleted 4\n\nabc\ndef\n")
        self.assertEqual(summary, ["deleted 4"])
        self.assertEqual(ids, ["abc", "def"])


@unittest.skipUnless(PG and all(MIGRATIONS.values()), "no test Postgres or migrations configured")
class AgainstMigratedSchemas(unittest.TestCase):
    def setUp(self):
        for name, directory in MIGRATIONS.items():
            migrate(f"reset_{name}", directory)

    def add_user(self, email: str) -> str:
        user_id = str(uuid.uuid4())
        psql("reset_db", f"""
            INSERT INTO users (id, email, password_hash, created_at) VALUES ('{user_id}', '{email}', 'x', now());
            INSERT INTO user_projections (id, user_id, name, season, data, created_at, updated_at, kind, player_id_space)
              VALUES (gen_random_uuid(), '{user_id}', 'Mine', '20262027', '{{}}', now(), now(), 'PROJECTION', 'yahoo');
            INSERT INTO projection_shares (id, projection_id, user_id, token, name, season, data, created_at, updated_at)
              SELECT gen_random_uuid(), id, user_id, md5(random()::text), name, season, data, now(), now()
              FROM user_projections WHERE user_id = '{user_id}';
            INSERT INTO password_reset_tokens (id, user_id, token_hash, expires_at, created_at)
              VALUES (gen_random_uuid(), '{user_id}', md5(random()::text), now(), now());
            INSERT INTO email_verification_tokens (id, user_id, token_hash, expires_at, created_at)
              VALUES (gen_random_uuid(), '{user_id}', md5(random()::text), now(), now());
            INSERT INTO subscriptions (id, user_id, provider, status, created_at, updated_at)
              VALUES (gen_random_uuid(), '{user_id}', 'stripe', 'active', now(), now());
            INSERT INTO pending_checkouts (user_id, provider, reference, checkout_url, created_at, updated_at)
              VALUES ('{user_id}', 'stripe', 'ref', 'https://example.com', now(), now());
            INSERT INTO premium_grants (id, user_id, granted_by, starts_at, expires_at, created_at)
              VALUES (gen_random_uuid(), '{user_id}', 'admin', now(), now(), now());
            INSERT INTO user_avatars (user_id, content_type, data, updated_at) VALUES ('{user_id}', 'image/png', '\\x00', now());
        """)
        psql("reset_yahoo", f"""
            INSERT INTO yahoo_oauth_tokens (app_user_id, access_token_enc, refresh_token_enc, access_expires_at, created_at, updated_at)
              VALUES ('{user_id}', 'a', 'r', now(), now(), now());
        """)
        psql("reset_espn", f"""
            INSERT INTO espn_credentials (app_user_id, espn_s2_enc, swid_enc, created_at, updated_at) VALUES ('{user_id}', 's2', 'swid', now(), now());
        """)
        return user_id

    def run_reset(self) -> list[str]:
        summary, ids = reset.parse_db_output(psql("reset_db", reset.db_sql(seeds())))
        psql("reset_yahoo", reset.yahoo_sql(ids))
        psql("reset_espn", reset.espn_sql(ids))
        self.summary = summary
        return ids

    def test_leaves_only_the_seeds_and_the_service_account(self):
        self.add_user("someone@example.com")
        self.add_user("e2e-hp-1789@slapstat.com")
        self.add_user("e2e@slapstat.com")  # the E2E account as sign-up made it, with another id
        psql("reset_yahoo", f"""
            INSERT INTO yahoo_oauth_tokens (app_user_id, access_token_enc, refresh_token_enc, access_expires_at, created_at, updated_at)
              VALUES ('{reset.YAHOO_SERVICE_ACCOUNT}', 'a', 'r', now(), now(), now());
        """)

        ids = self.run_reset()

        self.assertEqual(sorted(ids), sorted([reset.PREMIUM_ID, reset.FREE_ID, reset.E2E_ID]))
        self.assertIn("deleted 3", self.summary)
        for table in ("subscriptions", "pending_checkouts", "password_reset_tokens",
                      "email_verification_tokens", "projection_shares", "user_avatars"):
            self.assertEqual(psql("reset_db", f"SELECT count(*) FROM {table};").strip(), "0", table)
        self.assertEqual(
            psql("reset_db", "SELECT user_id FROM premium_grants;").strip(),
            reset.PREMIUM_ID,
        )
        self.assertEqual(
            psql("reset_db", "SELECT email FROM users WHERE id = '%s';" % reset.E2E_ID).strip(),
            "e2e@slapstat.com",
        )
        yahoo = psql("reset_yahoo", "SELECT app_user_id FROM yahoo_oauth_tokens;").split()
        self.assertEqual(yahoo, [reset.YAHOO_SERVICE_ACCOUNT])
        self.assertEqual(psql("reset_espn", "SELECT count(*) FROM espn_credentials;").strip(), "0")

    def test_seeds_a_draft_only_where_a_draft_belongs(self):
        self.run_reset()
        rows = psql("reset_db", f"""
            SELECT u.username || '|' || p.kind || '|' || coalesce(p.preset, '-') || '|' || (p.data ? 'draft')
                   || '|' || jsonb_array_length(p.data -> 'players')::text
            FROM user_projections p JOIN users u ON u.id = p.user_id ORDER BY 1;
        """).split("\n")
        rows = [row for row in rows if row]
        self.assertEqual(len(rows), 4)
        self.assertIn("premium_tester|PRESET_DRAFT|LAST_SEASON|true|1977", rows)
        self.assertIn("free_tester|PROJECTION|-|false|1977", rows)
        self.assertIn("premium_tester|PROJECTION|-|false|1587", rows)

    def test_running_twice_gives_the_same_baseline(self):
        first = self.run_reset()
        second = self.run_reset()
        self.assertEqual(first, second)
        self.assertIn("deleted 3", self.summary)
        self.assertEqual(psql("reset_db", "SELECT count(*) FROM user_projections;").strip(), "4")
        self.assertEqual(psql("reset_db", "SELECT count(*) FROM premium_grants;").strip(), "1")


if __name__ == "__main__":
    unittest.main()
