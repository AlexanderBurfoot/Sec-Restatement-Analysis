# SEC Restatement Analysis

A point-in-time data warehouse over the SEC's bulk XBRL filing data, built to
detect restatements: cases where a company published one value for a reported
figure and later published another for the same figure, same period, same unit.
Every numeric fact carries two dates (the period it describes and the date it
became public) and keeping those apart is what makes the comparison possible.
The warehouse also measures how long figures take to become public and where the
source fails basic validity checks.

Postgres and dbt over **42,797,341 numeric facts from 81,720 filings**,
2023 Q1 to 2025 Q4, from which **426,706 restatements** are detected.

## Headline findings

**Restatements do not arrive in amendments.** Only **8.26%** of the 426,706
detected revisions were carried by a form ending in `/A`. The other 91.7%
arrived inside an ordinary 10-Q or 10-K quietly carrying a revised comparative,
at a median of **364 days** after the figure was first published, with no marker
of any kind. Watching for amendments catches roughly one restatement in twelve.

**Revisions concentrate on the statement people read.** The income statement is
revised at 7.29% of revisable facts against 4.27% for the balance sheet.
Earnings per share is the most revised concept in the dataset: **one in ten
reported EPS figures is later published at a different value.**

**Revision predicts revision.** A figure revised once has a 7.78% chance of being
revised again; revised twice, 17.82%; revised three times, 22.94%. The count of
prior revisions is a usable risk signal and ships in `int_restatements`.

**One restatement in nine is not a revision of a value, and the report says
which.** Three categories were defined in advance and counted directly across the
whole population: **6,950 zero origin** facts first published as zero, **10,061
revisions above 10,000%**, and **29,118 sign flips** where the latest value is the
exact negation of the first. They are mutually disjoint, total **46,129 (10.81%)**,
and each is a reclassification, a rescaling or a sign correction rather than a
changed number. With the classes found by sampling, identifiable artefacts reach
about **16%** of the population, taking the rate to roughly **4.01%**.

**The downward skew survives it, and strengthens.** 57.76% of revisions are
reductions. Sign flips carry an identical magnitude either side, so their
direction is meaningless; excluding them gives **58.51%**, and excluding all three
artefact categories gives **60.02%**. Those categories are themselves strongly
upward, so they were diluting the result rather than causing it.

**Restating is normal, which inverts the data quality result.** 86.8% of
companies restate something and 54% do it in sustained runs of three or more
consecutive periods. **96% of large accelerated filers restate, against 88% of
non-accelerated ones**, and large filers restate 40% more facts each. That is
the opposite direction from data quality, where the smallest filers fail an
average of 0.54 rules against 0.07 for the largest, roughly eight times worse,
agreed on by four independent measures. A screen built on filer size catches one
of these problems and misses the other.

## Restatement detection

A restatement is one described fact reported at two different values by two
filings published on different dates. The partition key is

```
(cik, coregistrant, segments, tag, period_end_date, qtrs, unit_of_measure)
```

ordered by `filed_date`. `adsh` is deliberately absent as comparing across filings
is the entire mechanism. Three of those columns are false-positive guards rather
than identity, and they carry the result: holding the method fixed, the restated
share of revisable facts is 7.02% on `(cik, tag, period_end_date, qtrs,
unit_of_measure)` alone and **4.785%** on the full key. `segments` does almost
all of that work, by stopping segment-level figures being compared against
consolidated totals.

| Measure | Value |
|---|---|
| Facts reported on more than one date (revisable) | 8,918,472 |
| Restatements detected | 426,706 |
| Restatement rate | 4.785% |
| Companies restating | 7,544 of 8,693 (86.8%) |
| Arriving via an amendment (`/A`) | 8.26% |
| Median days to first revision | 364 |
| Revisions that are reductions | 57.76% |
| Reductions, excluding sign flips | 58.51% |
| Reductions, excluding all three artefact categories | 60.02% |
| Identifiable as artefact rather than revision | ~16% |

Below a **0.1% rounding threshold** a change is treated as a change in reported
precision rather than a restatement. It is a judgement call, not a bound derived
from a distribution, and [`docs/findings.md`](docs/findings.md) §2.8 gives the
full sensitivity: moving it across two orders of magnitude moves the rate from
5.12% to 3.59%.

## Data quality scorecard

Stage 1 applied eight quality rules to the same data. Each is documented in
[`docs/findings.md`](docs/findings.md) §1 with an executable predicate, root
cause where established, an honest label where not, verification results, and a
recommended action.

| Rule | Dimension | Severity | Rows affected | % |
|---|---|---|---|---|
| Null numeric value | completeness | High | 1,898,905 | 4.437 |
| Reporting duration exceeds ten years | validity | High | 951 | 0.0022 |
| Duplicate key with conflicting values | consistency | High | 300 | 0.0007 |
| Rejected at load: embedded delimiter | validity | Medium | 236 | 0.0006 |
| Filing lag exceeds three years | timeliness | Medium | 59 | 0.0722 |
| Balance sheet identity violation | accuracy | High | 12 | 0.0077 |
| Filed before the period it reports | validity | High | 4 | 0.0049 |

## Three results worth reading the detail for

**About 16% of detected restatements are not corrections, and the report says
which.** Verification ran two ways. Sampling twenty revisions and inspecting each
one's full report sequence found three artefact classes that were then measured
across the population: exact power-of-ten scale changes (11,846), precision
re-reporting where a later filing rounds a figure first published exactly (~4,420,
with a 13× asymmetry confirming the direction), and IAS 29 hyperinflation
re-presentation by Argentine issuers (9,725, four of which share a median revision
of *exactly* 211.4%). Three further categories were then defined in advance and
counted directly, with no sampling error: zero-origin facts (6,950),
revisions above 10,000% (10,061), and exact sign flips (29,118). Worked examples
carry each one, General Electric recasting FY2022 into discontinued operations
presentation with the *total* unchanged; Kamada moving 145 facts across 82 tags by
a factor of exactly 1,000; Aditxt's EPS falling 9,928× while its share count fell
10,005× in the same filing. Netting the overlaps, the headline rate survives at
about **4.01%**, the downward revision skew *strengthens* to 60.02%, and the
revision *magnitude* distribution does not survive unqualified.

**The documented natural key is incomplete.** The SEC publishes the primary key
of its numeric fact file without the `segments` column. Testing uniqueness on
that basis produced 4,635,667 violations. Adding `segments` reduced it to 154
genuine duplicates carrying conflicting values within a single filing, with gaps
up to 9,000% and frequently opposite signs.

**One of the quality rules over flags, and the report says so.** Verification of
the duration rule showed 77% of flagged rows fall in a band consistent with
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

`int_restatements` is deterministic: two consecutive builds return 426,706 rows
with identical checksums. That is a gate, not an accident. An earlier
formulation tiebroke conflicting same day values on accession number alone,
which is not a total order where the conflict sits inside one filing, and
consecutive builds disagreed.

## Structure

```
scripts/     fetch and load (the only Python in the project)
dbt/
  models/
    staging/   typed, tested views over the raw text
    marts/     dim_company (SCD2), dim_tag, dim_filing, dim_date,
               fct_financial_fact (incremental), int_restatements
    analysis/  the queries that produced the findings above
  tests/       singular tests; four fire as documented warnings
docs/
  findings.md  the analysis   §1 data quality, §2 restatements
```

All transformation is SQL. Python handles file acquisition and ingestion only.

## Scope and limitations

- **Not full history, and the restatement rate is biased downward by it.** The
  SEC publishes these datasets from 2009 Q2; this loads 2023 Q1 to 2025 Q4. Since
  the median revision arrives 364 days after first publication, revisions landing
  after 2025-12-31 are invisible. Facts first reported in 2023 restate at 5.35%;
  those first reported in 2025 restate at 2.35%. **4.785% is a lower bound.**
- **Detection cannot distinguish a correction from a reclassification.** The model
  observes that a published value changed, never why. Error corrections,
  reclassifications between tags, retroactive re-presentations and scale changes
  are indistinguishable in the values alone. A restatement here means "the
  published value for this fact changed", not "the filer got it wrong". The classes
  that leave a numeric signature are quantified (~16%); the general case (a figure
  moving between two tags that both already carry non-zero values) leaves no
  signature and is not counted anywhere.
- **External accuracy is untested.** One internal identity is checked (assets
  equal liabilities plus equity); confirming figures against reality would
  require an independent source.
- **No root cause is confirmed against source filings.** All causes are inferred
  from aggregate data and sampled report sequences, and labelled established,
  hypothesised, or not established.
- **Tag-type analysis joins on tag name alone**, ignoring taxonomy version.
- **236 rows were rejected at ingestion** and counted rather than silently
  dropped. They contain literal tab characters inside free text fields,
  producing more fields than the file's own header declares.

## Source

SEC Financial Statement Data Sets is public. No authentication required.
Bulk downloads require a `User Agent` header containing a contact address.
