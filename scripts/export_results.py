"""
Publish analysis model outputs as CSV and JSON.

CSV because GitHub renders it as a sortable table in the browser, so a reader
can check a figure without cloning anything. JSON because the same results are
easier to consume programmatically and carry their column types.

Both are generated from the live tables by this script. Neither is
hand-maintained, so a rebuild refreshes them and they cannot drift apart.
"""

import json
import os
from decimal import Decimal
from pathlib import Path

import psycopg
from dotenv import load_dotenv

load_dotenv()

OUT = Path(__file__).resolve().parents[1] / "docs" / "results"

TABLES = [
    "dq_scorecard",
    "dq_filing_lag_profile",
    "dq_custom_tag_share",
    "rst_by_sector",
    "rst_by_statement",
    "rst_by_filer_size",
]


def conn_string() -> str:
    return (
        f"host={os.getenv('POSTGRES_HOST', 'localhost')} "
        f"port={os.getenv('POSTGRES_PORT', '5433')} "
        f"dbname={os.getenv('POSTGRES_DB', 'sec')} "
        f"user={os.getenv('POSTGRES_USER', 'sec')} "
        f"password={os.getenv('POSTGRES_PASSWORD', 'sec')}"
    )


def encode(v):
    if isinstance(v, Decimal):
        return float(v)
    if hasattr(v, "isoformat"):
        return v.isoformat()
    return v


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    with psycopg.connect(conn_string()) as conn:
        for table in TABLES:
            with conn.cursor() as cur:
                # CSV
                with (OUT / f"{table}.csv").open("w") as fh:
                    with cur.copy(
                        f"copy (select * from public_analysis.{table}) "
                        f"to stdout with csv header"
                    ) as copy:
                        for chunk in copy:
                            fh.write(bytes(chunk).decode())

                # JSON
                cur.execute(f"select * from public_analysis.{table}")
                cols = [d.name for d in cur.description]
                rows = [
                    {c: encode(v) for c, v in zip(cols, r)}
                    for r in cur.fetchall()
                ]
                (OUT / f"{table}.json").write_text(
                    json.dumps(rows, indent=2) + "\n"
                )

            print(f"  {table}: {len(rows)} rows -> csv + json")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
