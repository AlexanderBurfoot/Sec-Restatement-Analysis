"""Print a build fingerprint for fct_financial_fact.

Idempotency check for the incremental model: two consecutive `dbt build` runs
must produce byte-identical output from this script. A changed row count means
the incremental filter is inserting or dropping rows on a no-op run; a changed
value sum with an unchanged row count means it is replacing them with different
ones.

Usage:
    python scripts/checksum.py [relation]
"""

from __future__ import annotations

import os
import sys

import psycopg
from dotenv import load_dotenv

load_dotenv()

DEFAULT_RELATION = "public_marts.fct_financial_fact"
KEY_COLUMNS = (
    "adsh",
    "tag",
    "taxonomy_version",
    "coregistrant",
    "segments",
    "period_end_date",
    "qtrs",
    "unit_of_measure",
)


def conn_string() -> str:
    """Same connection convention as load_raw.py, read from .env."""
    return (
        f"host={os.getenv('POSTGRES_HOST', 'localhost')} "
        f"port={os.getenv('POSTGRES_PORT', '5433')} "
        f"dbname={os.getenv('POSTGRES_DB', 'sec')} "
        f"user={os.getenv('POSTGRES_USER', 'sec')} "
        f"password={os.getenv('POSTGRES_PASSWORD', 'sec')}"
    )


def fingerprint_query(relation: str) -> str:
    """Row count, distinct natural-key count, and a sum over the measure.

    The distinct key count is reported separately from the row count because
    they are legitimately unequal: the SEC emits a small number of facts sharing
    a composite key. A change in the gap between them is the signal.
    """
    key_expression = ", ".join(KEY_COLUMNS)
    return f"""
        select
            count(*)                                     as row_count,
            count(distinct ({key_expression}))           as distinct_key_count,
            coalesce(sum(value), 0)                      as value_sum,
            count(*) filter (where value is null)        as null_value_count,
            max(filed_date)                              as max_filed_date
        from {relation}
    """


def main() -> int:
    relation = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_RELATION

    with psycopg.connect(conn_string()) as connection:
        with connection.cursor() as cursor:
            cursor.execute(fingerprint_query(relation))
            column_names = [column.name for column in cursor.description]
            values = cursor.fetchone()

    print(f"relation            {relation}")
    for name, value in zip(column_names, values):
        print(f"{name:<20}{value}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
