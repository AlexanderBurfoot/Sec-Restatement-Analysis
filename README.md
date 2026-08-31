# SEC Restatement Analysis

A point-in-time data warehouse over the SEC's bulk XBRL filing data, built to
detect restatements: cases where a company published one value for a reported
figure and later published another for the same figure, same period, same unit.
Every numeric fact carries two dates (the period it describes and the date it
became public) and keeping those apart is what makes the comparison possible.
The warehouse also measures how long figures take to become public, who files to
the deadline, where the source fails basic validity checks, and, the point of
keeping the two dates apart, what it costs to compare companies using figures
that did not exist on the date the comparison claims to stand on.

Postgres and dbt over **42,797,341 numeric facts from 81,720 filings**,
2023 Q1 to 2025 Q4, from which **426,706 restatements** are detected.

## Headline findings

**Comparing companies on restated figures reclassifies one in thirty-three into
a different quartile.** The same peer comparison was built twice over the
identical **3,441 companies** and the identical fiscal year: once from what was
knowable on 2024-06-30, once from everything filed since. Same metric, same peer
universe, same period, same code, the two views differ in one date and nothing
else. **103 companies land in a different performance quartile**, 42 of them
moving two or more and 13 moving three, and nothing on the output marks which
rows moved. The
largest single cause is not restatement but **industry reclassification: 19
companies changed SIC major group and 18 of the 19 moved quartile materially**,
including nine software and electronics firms that became financial firms after
the period. This is the result the two-date design exists to produce; no
warehouse that overwrites figures in place can measure it.

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

**Leaking two features across the filing date manufactures 0.11 to 0.13 of test
AUC.** Two feature tables over the same 58,726 filings, the same label and the
same deliberately trivial logistic regression, differing only in whether the
company's prior-restatement count and its sector base rate were computed as of
`filed_date` or over the whole loaded range. Point-in-time scores **0.59–0.61**
on unseen filings; the naive table scores **0.72**. Almost all of the difference
is one feature, a full-window restatement count that includes the very
restatement it is being asked to predict.

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

## Filing behaviour and point-in-time comparables

Stage 3 asks what the two dates are worth once they are kept apart. Four models,
documented in [`docs/findings.md`](docs/findings.md) §3.

**The original-to-amendment gap is 98 days.** §1.2 had inferred roughly 140 by
subtracting one median from another; pairing each amendment to the specific
original it amends gives 98, and removes amendments of pre-2023 originals from
both sides at once. The gradient inverts the data quality one: large accelerated
filers publish fastest and amend slowest, a median 159 days against 92 for
non-accelerated filers. The SEC's own `prevrpt` flag marks 1.20% of originals as
superseded where 1.87% are observably amended.

**Filing promptness has not drifted over twelve quarters.** None of the six
form-and-status series clears r² = 0.5, and seasonality is an order of magnitude
larger than any fitted trend, non-accelerated 10-K lag swings 27 days inside one
year against a slope of exactly zero. This is reported as a negative result, not
as evidence that no drift exists; the series is too short and too seasonal to
rule out a drift of under a day per year.

**2,862 companies file to the deadline habitually**, established by runs of three
or more consecutive filings found by gap-and-island rather than by a count, which
separates them from the 1,141 intermittent and 433 episodic companies that file
at the deadline nearly as often but never in a sustained run.

| Measure | Value |
|---|---|
| Companies compared point-in-time vs latest | 3,441 |
| Changed quartile on margin or growth | 264 |
| **Changed quartile materially** | **103** (96 after artefacts) |
| Caused by the company's own restated values | 88 (74 material) |
| Caused by SIC reclassification | 19 (18 material) |
| Caused by both | 7 (7 material) |
| Caused only by peers' figures moving | 150 (4 material) |
| Filings made at their statutory deadline | 25,782 of 69,907 (36.88%) |
| Filings late (range, see below) | 6.46% – 11.97% |

**The late-filing rate is published as a range because the data cannot narrow
it.** 8,371 filings miss the statutory due date, but 3,856 of those land inside
the Rule 12b-25 extension window and were probably deemed timely. Form 12b-25
carries no XBRL and is therefore absent from the SEC's financial statement data
sets, so whether the extension was actually invoked is unobservable here.
§3.5 also finds that roughly 290 late flags are federal-holiday artefacts, 236 of
them sharing a single due date.

## What point-in-time discipline is worth

Stage 4 prices the two-date mechanic against a prediction rather than a ranking.
Two feature tables over the same **58,726 filings**, every 10-K and 10-Q with a
complete observation window, carrying the same label (did this filing publish a
consolidated figure revised within 180 days) and the same five features. The only
difference is whether the company's prior-restatement count and its sector base
rate were computed from what was knowable at `filed_date` or from the whole
loaded range. `scripts/train_compare.py` fits the same logistic regression to
both, training on filings before 2025 and testing on filings after, never a
random split: these are panel data and a random split lets the model recognise
the company instead of predicting anything.

| Feature set | Test AUC |
|---|---|
| Point-in-time | 0.5894 – 0.6102 |
| Naive | 0.7172 – 0.7218 |
| **Gap** | **0.1116 – 0.1278** |

**Between 0.11 and 0.13 of test AUC is information from after the filing date.**
That is the distance between a weak but honest model and one that reads as a
usable early-warning screen, and nothing on the naive table marks it, same rows,
same label, same five column names.

The model is deliberately trivial and is not the deliverable: scikit-learn's
default logistic regression on standardised inputs, no tuning, no class
weighting, no feature engineering. A better model would raise both numbers. The
gap is the point.

**Almost all of it is one feature.** `prior_restatement_count` over the full
window scores 0.7180 on its own, higher than the entire fitted naive model,
because the restatement that sets the label is one of the events it counts.
Point-in-time, the same feature scores 0.5669. The range is quoted rather than a
single number because the point-in-time sector rate has no history to read during
the first months of the loaded range, and the second figure in each row drops
those warm-up rows from both models' training sets identically.

**The gap does not turn on the 180-day label horizon.** Rebuilt at 90, 120, 180,
240 and 270 days, one var, with the population, the label, both feature tables
and both singular tests following from it, the gap sits between 0.115 and 0.130
across the first four. The 270-day point is larger (0.168) and is discounted: its
test set is a single annual-report quarter of 5,277 filings.
[`docs/findings.md`](docs/findings.md) §4 sets out the label design, the
sensitivity, the verification, and what the range does and does not establish.

## Query performance

Three optimisations measured before and after against the 42.8M-row fact table,
with full plans, block counts and interleaved timings in
[`docs/performance.md`](docs/performance.md).

| # | Query | Before | After | Change | Result |
|---|---|---|---|---|---|
| 1 | Restatement self-join, 20 filers | 57.0 s | **2.31 s** | B-tree `(cik, tag, period_end_date)`, 1027 MB | **25×** |
| 2 | One month of facts by `filed_date` | 8.0 s | 6.4 s | BRIN on `filed_date`, 376 kB | **no change, identical plan** |
| 2b | *same query* | 8.0 s | **1.01 s** | B-tree on `filed_date`, 283 MB | **8×**, at 771× the index size |
| 3 | First/latest value per described fact | 30.0 s | **10.6 s** | correlated subquery → window function | **2.8×** |
| 3b | *same, 3.6× the rows* | 192.2 s | **10.3 s** | *same* | **18.6×** |

Case 2 is a negative result and is documented at length because of it: BRIN was
the wrong instrument for a column with a correlation of 0.029, and case 2b is the
control proving the query was improvable anyway. The document also records that
the measurement environment degraded ~45% mid-session, invalidating a first round
of numbers; every figure above comes from a single clean pass taken afterwards.

Every index created for these measurements was dropped afterwards. The table
ships with one index, on `financial_fact_sk`.

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
scripts/     fetch, load, build fingerprint, and the Stage 4 model comparison
dbt/
  models/
    staging/   typed, tested views over the raw text
    marts/     dim_company (SCD2), dim_tag, dim_filing, dim_date,
               fct_financial_fact (incremental), int_restatements
    analysis/  the queries that produced the findings above
  tests/       10 singular tests; 5 tests warn, each documented in findings.md
docs/
  findings.md     the analysis   §1 data quality, §2 restatements,
                  §3 filing behaviour and point-in-time comparables,
                  §4 what point-in-time discipline is worth
  performance.md  three query optimisations, measured
```

All transformation is SQL. Python handles file acquisition, ingestion and one
scikit-learn call; no aggregation happens outside the database.

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
- **The late-filing rate is a range, not a number.** Rule 12b-25 grants an
  automatic extension that the source data cannot confirm was invoked, because
  Form 12b-25 carries no XBRL. Newly public companies, transition reports and
  federal holidays are three further deadline exceptions not modelled;
  [`docs/findings.md`](docs/findings.md) §3.5 measures the last of them.
- **The point-in-time comparison rests on four tags and one cutoff date.**
  Revenue under three tags plus `NetIncomeLoss`, consolidated, USD, annual. The
  103 is what eighteen months of subsequent filings did to one fiscal year seen
  from 2024-06-30; no sensitivity across other cutoffs was run.
- **The 0.11–0.13 AUC gap belongs to these two constructions, not to leakage in
  general.** A naive table that leaked through fewer features would show less; one
  with more full-window aggregates would show more. The test period is six
  months, and the point-in-time model is additionally handicapped by a sector-rate
  warm-up that a longer loaded range would remove.

## Source

SEC Financial Statement Data Sets is public. No authentication required.
Bulk downloads require a `User Agent` header containing a contact address.
