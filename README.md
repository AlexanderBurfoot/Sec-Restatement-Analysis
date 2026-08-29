# SEC Restatement Analysis

A point int ime data warehouse over the SEC's bulk XBRL filing data, built to
measure when reported figures actually become public, where the source fails
basic validity checks, and which filers produce those failures.

Postgres and dbt over **42,797,341 numeric facts from 81,720 filings**,
2023 Q1 to 2025 Q4.

## Headline findings

**Data quality grades sharply with filer size.** Non-accelerated filers (the
smallest SEC size category), fail an average of 0.54 quality rules against 0.07
for large accelerated filers, roughly eight times worse. Four independent
measures agree: extension tag usage, unit type inconsistency, null rates, and
every one of the twelve material balance sheet violations found.

**Defects are concentrated, not systemic.** 69% of the 8,693 filers examined
fail no rule at all; only three fail three or more. Filer level screening is a
more effective remediation than blanket filtering making it a materially different
conclusion from what the raw defect counts alone would suggest.

**Amended filings arrive a median 207 days after the period they cover**, about
140 days after the original. Anyone acting on a reported figure carries months
of exposure before a revision could exist, with nothing in the original to
signal one is coming.

## Data quality scorecard

| Rule | Dimension | Severity | Rows affected | % |
|---|---|---|---|---|
| Null numeric value | completeness | High | 1,898,905 | 4.437 |
| Reporting duration exceeds ten years | validity | High | 951 | 0.0022 |
| Duplicate key with conflicting values | consistency | High | 300 | 0.0007 |
| Rejected at load: embedded delimiter | validity | Medium | 236 | 0.0006 |
| Filing lag exceeds three years | timeliness | Medium | 59 | 0.0722 |
| Balance sheet identity violation | accuracy | High | 12 | 0.0077 |
| Filed before the period it reports | validity | High | 4 | 0.0049 |

Each rule is documented in [`docs/findings.md`](docs/findings.md) with an
executable predicate, root cause where established, an honest label where not,
verification results, and a recommended action.

## Two results worth reading the detail for

**The documented natural key is incomplete.** The SEC publishes the primary key
of its numeric fact file without the `segments` column. Testing uniqueness on
that basis produced 4,635,667 violations. Adding `segments` reduced it to 154
genuine duplicates carrying conflicting values within a single filing, with
gaps up to 9,000% and frequently opposite signs.

**One of the rules over flags, and the report says so.** Verification of the
duration rule showed 77% of flagged rows fall in a band consistent with
legitimate inception to date reporting by development stage companies. Only 15
facts across 2 filings are unambiguously defective. The rule is retained with
that caveat rather than silently retuned to look cleaner.

## Running it

```bash
cp .env.example .env          # set SEC_USER_AGENT to a real contact string
make up                       # Postgres 16 in Docker
make fetch                    # downloads quarterly bulk files from sec.gov
make load                     # tab-delimited COPY into a raw schema
cd dbt && dbt deps && dbt build
```

Requires Python 3.12 (dbt-core does not yet support 3.13+) and Docker.

## Structure

```
scripts/     fetch and load (the only Python in the project)
dbt/
  models/
    staging/   typed, tested views over the raw text
    analysis/  the queries that produced the findings above
  tests/       singular tests; four fire as documented warnings
docs/
  findings.md  the analysis
```

All transformation is SQL. Python handles file acquisition and ingestion only.

## Scope and limitations

- **Not full history.** The SEC publishes these datasets from 2009 Q2; this loads
  2023 Q1 to 2025 Q4 to keep the working set on one machine while retaining enough
  time depth for amendments to appear against their originals.
- **External accuracy is untested.** One internal identity is checked (assets
  equal liabilities plus equity); confirming figures against reality would
  require an independent source.
- **No root cause is confirmed against source filings.** All causes are inferred
  from aggregate data and labelled established, hypothesised, or not established.
- **Tag-type analysis joins on tag name alone**, ignoring taxonomy version.
- **236 rows were rejected at ingestion** and counted rather than silently
  dropped. They contain literal tab characters inside free text fields,
  producing more fields than the file's own header declares.

## Source

SEC Financial Statement Data Sets is public. No authentication required.
Bulk downloads require a `User Agent` header containing a contact address.
