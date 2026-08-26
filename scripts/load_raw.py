"""
Load SEC quarterly ZIPs into a `raw` schema as untyped TEXT columns.

Three things this handles that a naive loader does not:

1. The files are TAB delimited, not comma.
2. They contain stray unescaped double quotes in text fields (company names,
   footnotes). Standard CSV parsing chokes on these. Setting the quote character
   to a byte that never appears in the data effectively disables quote handling,
   which is correct here -- these files do not use quoting at all.
3. Each table gets a `source_quarter` column so every row traces back to the ZIP
   it came from. Needed for incremental loads and for debugging.

Columns are read from each file's own header rather than hardcoded, because the
SEC has added fields over the years and older quarters have fewer.
"""

import os
import sys
import zipfile
from pathlib import Path

import psycopg
from dotenv import load_dotenv

load_dotenv()

RAW_DIR = Path(__file__).resolve().parents[1] / "data" / "raw"

# file inside the zip -> raw table name
MEMBERS = {
    "sub.txt": "sub",
    "num.txt": "num",
    "pre.txt": "pre",
    "tag.txt": "tag",
}


def conn_string() -> str:
    return (
        f"host={os.getenv('POSTGRES_HOST', 'localhost')} "
        f"port={os.getenv('POSTGRES_PORT', '5433')} "
        f"dbname={os.getenv('POSTGRES_DB', 'sec')} "
        f"user={os.getenv('POSTGRES_USER', 'sec')} "
        f"password={os.getenv('POSTGRES_PASSWORD', 'sec')}"
    )


def load_member(cur, zf, member: str, table: str, quarter: str) -> int:
    with zf.open(member) as fh:
        header = fh.readline().decode("utf-8", errors="replace").rstrip("\r\n")
        cols = header.split("\t")

        col_ddl = ", ".join(f'"{c}" text' for c in cols)
        cur.execute(
            f"create table if not exists raw.{table} "
            f"({col_ddl}, source_quarter text)"
        )

        # The default supplies source_quarter for every row this COPY inserts,
        # so the column never appears in the column list and needs no UPDATE.
        cur.execute(
            f"alter table raw.{table} "
            f"alter column source_quarter set default '{quarter}'"
        )

        col_list = ", ".join(f'"{c}"' for c in cols)
        copy_sql = (
            f"copy raw.{table} ({col_list}) from stdin with "
            f"(format csv, delimiter E'\\t', quote E'\\b', null '')"
        )

        rows = 0
        with cur.copy(copy_sql) as copy:
            while chunk := fh.read(1 << 22):
                copy.write(chunk)
                rows += chunk.count(b"\n")

    return rows


def main() -> int:
    zips = sorted(RAW_DIR.glob("*.zip"))
    if not zips:
        print(f"No ZIPs in {RAW_DIR}. Run `make fetch` first.", file=sys.stderr)
        return 1

    with psycopg.connect(conn_string()) as conn:
        with conn.cursor() as cur:
            cur.execute("create schema if not exists raw")
            # Full reload each run. Incremental arrives in Stage 2.
            for table in MEMBERS.values():
                cur.execute(f"drop table if exists raw.{table}")
            conn.commit()

            for path in zips:
                quarter = path.stem
                with zipfile.ZipFile(path) as zf:
                    names = {n.lower(): n for n in zf.namelist()}
                    for member, table in MEMBERS.items():
                        actual = names.get(member)
                        if actual is None:
                            print(f"  {quarter}: {member} missing", file=sys.stderr)
                            continue
                        rows = load_member(cur, zf, actual, table, quarter)
                        print(f"  {quarter} {table:<4} {rows:>11,}")
                conn.commit()

            print()
            for table in MEMBERS.values():
                cur.execute(f"select count(*) from raw.{table}")
                print(f"raw.{table:<5} {cur.fetchone()[0]:>13,} rows")
        conn.commit()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
