# SEC Restatement Analysis

> **Stage 1 in progress.** Replace this block before tagging `v1-data-quality`.
> The README must describe what exists now — no "coming soon", no visible TODOs.

Data quality analysis of the SEC's bulk XBRL filing data. Quantifies how long
after a reporting period its numbers actually become public, how much of the
data is company-specific and therefore hard to compare, and where the source
data fails basic validity checks.

Built on Postgres and dbt over `____` numeric facts from `____` filings,
quarters `____` to `____`.

## Headline findings

_Three numbers. Written last, placed first._

1.
2.
3.

## Data quality scorecard

_Paste `dq_scorecard` output._

## Running it

```bash
cp .env.example .env          # set SEC_USER_AGENT to a real contact string
make up
make fetch
make load
make build
```

## Notes

- Source: SEC Financial Statement Data Sets (public, no authentication)
- Loaded range is stated above and is not full history
- Custom tag detection uses `version = adsh`, the SEC's own convention
