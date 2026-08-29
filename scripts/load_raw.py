"""Load SEC quarterly ZIPs into a raw schema as untyped TEXT columns.

Handles tab delimiters, unquoted text containing stray double quotes, source
schema drift across quarters, and rows whose free text fields contain embedded
tabs. That last case cannot be repaired reliably, so those rows are rejected and
counted in raw.load_rejects.
"""

import os
import sys
import zipfile
from pathlib import Path

import psycopg
import psycopg.sql
from dotenv import load_dotenv

load_dotenv()

RAW_DIR = Path(__file__).resolve().parents[1] / "data" / "raw"
FLUSH_EVERY = 50_000

MEMBERS = {"sub.txt": "sub", "num.txt": "num", "pre.txt": "pre", "tag.txt": "tag"}


def conn_string() -> str:
    return (
        f"host={os.getenv('POSTGRES_HOST', 'localhost')} "
        f"port={os.getenv('POSTGRES_PORT', '5433')} "
        f"dbname={os.getenv('POSTGRES_DB', 'sec')} "
        f"user={os.getenv('POSTGRES_USER', 'sec')} "
        f"password={os.getenv('POSTGRES_PASSWORD', 'sec')}"
    )


def existing_columns(cur, table):
    cur.execute(
        "select column_name from information_schema.columns "
        "where table_schema = 'raw' and table_name = %s",
        (table,),
    )
    return {r[0] for r in cur.fetchall()}


def reconcile_schema(cur, table, cols):
    present = existing_columns(cur, table)
    if not present:
        col_ddl = ", ".join(f'"{c}" text' for c in cols)
        cur.execute(f"create table raw.{table} ({col_ddl}, source_quarter text)")
        return []
    added = [c for c in cols if c not in present]
    for col in added:
        cur.execute(f'alter table raw.{table} add column "{col}" text')
    return added


def load_member(cur, zf, member, table, quarter):
    with zf.open(member) as fh:
        header = fh.readline().decode("utf-8", errors="replace").rstrip("\r\n")
        cols = header.split("\t")
        ncols = len(cols)

        added = reconcile_schema(cur, table, cols)
        cur.execute(
            f"alter table raw.{table} "
            f"alter column source_quarter set default {psycopg.sql.Literal(quarter).as_string(cur)}"
        )

        col_list = ", ".join(f'"{c}"' for c in cols)
        copy_sql = (
            f"copy raw.{table} ({col_list}) from stdin with "
            f"(format csv, delimiter E'\\t', quote E'\\b', null '')"
        )

        rows = 0
        rejected = 0
        buf = bytearray()
        with cur.copy(copy_sql) as copy:
            for raw_line in fh:
                line = raw_line.rstrip(b"\r\n")
                if not line:
                    continue
                if line.count(b"\t") != ncols - 1:
                    rejected += 1
                    continue
                buf += line + b"\n"
                rows += 1
                if rows % FLUSH_EVERY == 0:
                    copy.write(bytes(buf))
                    buf.clear()
            if buf:
                copy.write(bytes(buf))

    if rejected:
        cur.execute(
            "insert into raw.load_rejects "
            "(source_quarter, source_file, expected_columns, rows_rejected) "
            "values (%s, %s, %s, %s)",
            (quarter, member, ncols, rejected),
        )
    return rows, rejected, added


def main() -> int:
    zips = sorted(RAW_DIR.glob("*.zip"))
    if not zips:
        print(f"No ZIPs in {RAW_DIR}. Run `make fetch` first.", file=sys.stderr)
        return 1

    print(f"{len(zips)} quarters to load: {zips[0].stem} .. {zips[-1].stem}\n")

    with psycopg.connect(conn_string()) as conn:
        with conn.cursor() as cur:
            cur.execute("create schema if not exists raw")
            for table in MEMBERS.values():
                cur.execute(f"drop table if exists raw.{table}")
            cur.execute("drop table if exists raw.load_rejects")
            cur.execute(
                "create table raw.load_rejects ("
                "source_quarter text, source_file text, "
                "expected_columns int, rows_rejected bigint)"
            )
            conn.commit()

            total_rejected = 0
            for path in zips:
                quarter = path.stem
                with zipfile.ZipFile(path) as zf:
                    names = {n.lower(): n for n in zf.namelist()}
                    for member, table in MEMBERS.items():
                        actual = names.get(member)
                        if actual is None:
                            print(f"  {quarter}: {member} missing", file=sys.stderr)
                            continue
                        rows, rejected, added = load_member(
                            cur, zf, actual, table, quarter
                        )
                        total_rejected += rejected
                        notes = []
                        if rejected:
                            notes.append(f"{rejected:,} rejected")
                        if added:
                            notes.append(f"+cols {', '.join(added)}")
                        suffix = f"   [{'; '.join(notes)}]" if notes else ""
                        print(f"  {quarter} {table:<4} {rows:>11,}{suffix}")
                conn.commit()

            print()
            for table in MEMBERS.values():
                cur.execute(f"select count(*) from raw.{table}")
                print(f"raw.{table:<5} {cur.fetchone()[0]:>13,} rows")
            print(f"\n{total_rejected:,} rows rejected for malformed field counts")
        conn.commit()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
