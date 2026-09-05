"""
Publish data quality metrics as JSON, and check a fresh run against the
committed baseline.

Two modes:

    python scripts/export_metrics.py            write docs/results/quality_metrics.json
    python scripts/export_metrics.py --check    compare a fresh run against it

The committed file is the baseline. Loading a new quarter and re-running with
--check reports any rule whose rate moved beyond tolerance, which is the
question that matters after an incremental load: did quality regress, and where.

JSON rather than CSV because the comparison is structural. A rule can be added
or removed between runs, and a flat table gives no clean way to express that.
"""

import argparse
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

import psycopg
from dotenv import load_dotenv

load_dotenv()

OUT = Path(__file__).resolve().parents[1] / "docs" / "results" / "quality_metrics.json"

# A rule may drift this far before it is reported. Wider than measurement noise,
# narrower than a real regression. Stated here rather than buried in a compare.
TOLERANCE_PCT_POINTS = 0.05


def conn_string() -> str:
    return (
        f"host={os.getenv('POSTGRES_HOST', 'localhost')} "
        f"port={os.getenv('POSTGRES_PORT', '5433')} "
        f"dbname={os.getenv('POSTGRES_DB', 'sec')} "
        f"user={os.getenv('POSTGRES_USER', 'sec')} "
        f"password={os.getenv('POSTGRES_PASSWORD', 'sec')}"
    )


def collect(cur) -> dict:
    cur.execute("select version()")
    pg_version = cur.fetchone()[0].split(",")[0]

    cur.execute(
        "select min(source_quarter), max(source_quarter), count(distinct source_quarter) "
        "from raw.sub"
    )
    first_q, last_q, n_q = cur.fetchone()

    cur.execute("select count(*) from public_staging.stg_submissions")
    filings = cur.fetchone()[0]
    cur.execute("select count(*) from public_staging.stg_numeric")
    facts = cur.fetchone()[0]
    cur.execute("select count(*) from public_marts.int_restatements")
    restatements = cur.fetchone()[0]

    cur.execute(
        "select rule_name, dimension, severity, rows_affected, rows_checked, pct_affected "
        "from public_analysis.dq_scorecard order by rule_name"
    )
    rules = [
        {
            "rule": r[0],
            "dimension": r[1],
            "severity": r[2],
            "rows_affected": int(r[3]),
            "rows_checked": int(r[4]),
            "pct_affected": float(r[5]),
        }
        for r in cur.fetchall()
    ]

    cur.execute(
        "select count(*) filter (where first_reported_value = 0),"
        "       count(*) filter (where abs(pct_revision) > 100),"
        "       count(*) filter (where first_reported_value = -latest_reported_value"
        "                          and first_reported_value <> 0),"
        "       count(*) filter (where revision_direction = 'decrease')"
        " from public_marts.int_restatements"
    )
    zero_origin, extreme, sign_flip, downward = cur.fetchone()

    return {
        "generated_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "data_vintage": {
            "first_quarter": first_q,
            "last_quarter": last_q,
            "quarters_loaded": n_q,
        },
        "environment": {"postgres": pg_version},
        "dataset": {
            "filings": filings,
            "numeric_facts": facts,
            "restatements_detected": restatements,
        },
        "quality_rules": rules,
        "restatement_classes": {
            "zero_origin": zero_origin,
            "extreme_magnitude": extreme,
            "sign_flip": sign_flip,
            "downward_pct": round(100.0 * downward / restatements, 2)
            if restatements
            else None,
        },
        "tolerance_pct_points": TOLERANCE_PCT_POINTS,
    }


def compare(baseline: dict, current: dict) -> int:
    """Report rule-level drift. Returns a shell exit code."""
    base = {r["rule"]: r for r in baseline["quality_rules"]}
    curr = {r["rule"]: r for r in current["quality_rules"]}

    print(f"baseline: {baseline['generated_at']}  "
          f"({baseline['data_vintage']['quarters_loaded']} quarters)")
    print(f"current:  {current['generated_at']}  "
          f"({current['data_vintage']['quarters_loaded']} quarters)\n")

    drifted = 0

    for rule in sorted(set(base) | set(curr)):
        if rule not in curr:
            print(f"  REMOVED  {rule}")
            drifted += 1
            continue
        if rule not in base:
            print(f"  NEW      {rule}  {curr[rule]['pct_affected']}%")
            drifted += 1
            continue

        delta = curr[rule]["pct_affected"] - base[rule]["pct_affected"]
        if abs(delta) > TOLERANCE_PCT_POINTS:
            print(f"  DRIFT    {rule}: "
                  f"{base[rule]['pct_affected']}% -> {curr[rule]['pct_affected']}% "
                  f"({delta:+.3f} points)")
            drifted += 1

    if drifted:
        print(f"\n{drifted} rule(s) moved beyond {TOLERANCE_PCT_POINTS} points.")
        return 1

    print("  no rule moved beyond tolerance")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true",
                    help="compare a fresh run against the committed baseline")
    args = ap.parse_args()

    with psycopg.connect(conn_string()) as conn:
        with conn.cursor() as cur:
            current = collect(cur)

    if args.check:
        if not OUT.exists():
            print(f"No baseline at {OUT}. Run without --check first.", file=sys.stderr)
            return 1
        return compare(json.loads(OUT.read_text()), current)

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(current, indent=2) + "\n")
    print(f"wrote {OUT}")
    print(f"  {len(current['quality_rules'])} rules, "
          f"{current['dataset']['numeric_facts']:,} facts, "
          f"{current['dataset']['restatements_detected']:,} restatements")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
