"""
Download SEC Financial Statement Data Sets quarterly ZIPs.

The SEC requires a User-Agent header containing a real contact string. Requests
without one get blocked, and sustained requests above ~10/sec get rate limited.
Set SEC_USER_AGENT in .env.

Resumable: a ZIP already on disk with a plausible size is skipped, so re-running
after an interrupted download costs nothing.

VERIFY THE URL PATTERN before first run. The SEC has reorganised its DERA pages
before. Open the Financial Statement Data Sets page, right-click any quarterly
link, and confirm the path below matches.
"""

import os
import sys
import time
from pathlib import Path

import requests
from dotenv import load_dotenv

load_dotenv()

BASE_URL = "https://www.sec.gov/files/dera/data/financial-statement-data-sets"
RAW_DIR = Path(__file__).resolve().parents[1] / "data" / "raw"
MIN_PLAUSIBLE_BYTES = 1_000_000  # a real quarter is tens of MB


def quarters(start: str, end: str) -> list[str]:
    """Inclusive range of 'YYYYqN' strings."""
    sy, sq = int(start[:4]), int(start[5])
    ey, eq = int(end[:4]), int(end[5])
    out = []
    y, q = sy, sq
    while (y, q) <= (ey, eq):
        out.append(f"{y}q{q}")
        q += 1
        if q == 5:
            q = 1
            y += 1
    return out


def fetch_one(session: requests.Session, quarter: str) -> tuple[str, int, bool]:
    dest = RAW_DIR / f"{quarter}.zip"
    if dest.exists() and dest.stat().st_size > MIN_PLAUSIBLE_BYTES:
        return quarter, dest.stat().st_size, True

    url = f"{BASE_URL}/{quarter}.zip"
    resp = session.get(url, stream=True, timeout=60)
    if resp.status_code == 404:
        return quarter, 0, False
    resp.raise_for_status()

    tmp = dest.with_suffix(".zip.part")
    with tmp.open("wb") as fh:
        for chunk in resp.iter_content(chunk_size=1 << 20):
            fh.write(chunk)
    tmp.rename(dest)
    return quarter, dest.stat().st_size, False


def main() -> int:
    ua = os.getenv("SEC_USER_AGENT", "").strip()
    if not ua or "@" not in ua:
        print(
            "SEC_USER_AGENT must be set in .env and contain a contact email.\n"
            'Example: SEC_USER_AGENT=Al Burfoot al@aurumquanta.com',
            file=sys.stderr,
        )
        return 1

    RAW_DIR.mkdir(parents=True, exist_ok=True)
    wanted = quarters(
        os.getenv("SEC_START_QUARTER", "2019q1"),
        os.getenv("SEC_END_QUARTER", "2026q1"),
    )

    session = requests.Session()
    session.headers.update({"User-Agent": ua, "Accept-Encoding": "gzip, deflate"})

    total = 0
    missing = []
    for q in wanted:
        try:
            name, size, cached = fetch_one(session, q)
        except requests.HTTPError as exc:
            print(f"{q:<8} HTTP error: {exc}", file=sys.stderr)
            missing.append(q)
            continue

        if size == 0:
            print(f"{q:<8} not published yet")
            missing.append(q)
        else:
            total += size
            tag = "cached" if cached else "downloaded"
            print(f"{q:<8} {size / 1e6:>8.1f} MB  {tag}")

        if not cached:
            time.sleep(0.2)  # stay well under the SEC rate limit

    have = len(wanted) - len(missing)
    print(f"\n{have} quarters on disk, {total / 1e9:.2f} GB total")
    if missing:
        print(f"not available: {', '.join(missing)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
