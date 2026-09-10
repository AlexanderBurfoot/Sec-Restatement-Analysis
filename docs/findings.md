# Findings

**Report date:** §1 2026-08-28 · §2 2026-08-30 · §3 2026-08-31 · §4 2026-09-01
**Data vintage:** SEC Financial Statement Data Sets, 2023Q1–2025Q4, downloaded 2026-08-23
**Dataset:** 81,720 filings · 42,797,341 numeric facts · 426,706 detected restatements
**Environment:** PostgreSQL 16.15 · dbt-core 1.12.3 · dbt-postgres 1.11.0 · Python 3.12.14
**Reference point:** §1 at tag `v1-data-quality`; §2 at tag `v2-restatements`;
§3 at tag `v3-filing-behaviour`; §4 at tag `v4-point-in-time`
**Author:** Alexander Burfoot

Every figure in this document is reproducible from the repository at the tag
above by running `make up && make fetch && make load && dbt build`, then querying
the models under the `analysis` and `marts` schemas.

## Contents

- [Executive summary](#executive-summary)
- [§1 Data quality of SEC XBRL filings](#1-data-quality-of-sec-xbrl-filings)
  - [1.1 Scorecard](#11-scorecard)
  - [1.2 How long until a reported number is public?](#12-how-long-until-a-reported-number-is-public)
  - [1.3 Custom tag usage by company size](#13-custom-tag-usage-by-company-size)
  - [1.4 Units of measure](#14-units-of-measure)
  - [1.5 Missing values](#15-missing-values)
  - [1.6 Conflicting duplicate values](#16-conflicting-duplicate-values)
  - [1.7 Rows rejected at ingestion](#17-rows-rejected-at-ingestion)
  - [1.8 Issue register](#18-issue-register)
  - [1.9 Verification](#19-verification)
  - [1.10 Balance sheet reconciliation](#110-balance-sheet-reconciliation)
  - [1.11 Concentration](#111-concentration)
- [§2 Restatements (Stage 2)](#2-restatements-stage-2)
  - [2.1 Which sectors restate most](#21-which-sectors-restate-most)
  - [2.2 How large are revisions](#22-how-large-are-revisions)
  - [2.3 Which line items get revised](#23-which-line-items-get-revised)
  - [2.4 Do restatements cluster in time](#24-do-restatements-cluster-in-time)
  - [2.5 Does one restatement predict another](#25-does-one-restatement-predict-another)
  - [2.6 Serial restaters](#26-serial-restaters)
  - [2.7 Verification](#27-verification)
  - [2.8 Limitations](#28-limitations)
- [§3 Filing behaviour and comparables (Stage 3)](#3-filing-behaviour-and-comparables-stage-3)
  - [3.1 Filing lag by form and filer status](#31-filing-lag-by-form-and-filer-status)
  - [3.2 Has the wait moved across the twelve quarters?](#32-has-the-wait-moved-across-the-twelve-quarters)
  - [3.3 Filers who work to the deadline](#33-filers-who-work-to-the-deadline)
  - [3.4 Point-in-time peer comparables](#34-point-in-time-peer-comparables)
  - [3.5 Verification](#35-verification)
  - [3.6 Limitations](#36-limitations)
- [§4 What point-in-time discipline is worth (Stage 4)](#4-what-point-in-time-discipline-is-worth-stage-4)
  - [4.1 The result](#41-the-result)
  - [4.2 Where the gap comes from](#42-where-the-gap-comes-from)
  - [4.3 Does the gap depend on the horizon?](#43-does-the-gap-depend-on-the-horizon)
  - [4.4 Verification](#44-verification)
  - [4.5 Limitations](#45-limitations)

---

## Executive summary

Twelve quarters of SEC XBRL filing data, examined four ways. §1 tests each
filing against itself. §2 tests filings against each other. §3 asks what the two
dates are worth once kept apart. §4 prices the cost of ignoring them.

### Restatements (§2)

**Restatements do not arrive in amendments.** 426,706 revisions across 4.785% of
revisable facts. Only 8.26% came in a form ending in `/A`. The rest arrived
inside an ordinary 10-Q or 10-K carrying a revised comparative, median 364 days
later, unmarked. Watching for amendments catches one restatement in twelve.

**Revisions concentrate on the statement people read.** Income statement 7.29%
against 4.27% for the balance sheet. Earnings per share is the most revised
concept in the dataset: one in ten reported EPS figures is later published at a
different value.

**Revision predicts revision.** Revised once, 7.78% chance of being revised
again. Twice, 17.82%. Three times, 22.94%. The count of prior revisions is
already in `int_restatements` and needs no model.

**Restating is normal, which inverts §1.** 86.8% of companies restate something.
96% of large accelerated filers do, against 88% of non-accelerated, and large
filers restate 40% more facts each. That runs opposite to the data quality
gradient below.

**Roughly one restatement in nine is not a revision of a value.** Three
categories, defined in advance and counted across the whole population: 6,950
zero-origin facts, 10,061 revisions above 10,000%, 29,118 sign flips. Disjoint,
totalling 46,129 or 10.81%. Add the classes found by sampling and identifiable
artefacts reach about 16%, taking the rate to roughly 4.01%.

**The downward skew survives that.** 57.76% of revisions are reductions.
Excluding sign flips gives 58.51%; excluding all three artefact classes gives
60.02%. They were diluting the finding, not causing it.

### Data quality (§1)

**Quality grades sharply with filer size.** Non-accelerated filers fail 0.54
rules on average against 0.07 for large accelerated. Four independent measures
agree: extension tag usage, unit type inconsistency, balance sheet violations,
aggregate rule failures. All twelve material balance sheet violations come from
non-accelerated filers.

**Defects are concentrated.** 69% of 8,693 filers fail nothing. Three fail three
or more. Filer-level screening beats blanket filtering.

**Missing values dominate by volume.** 4.4% of facts carry a tag, a period and a
unit but no number. That is 1.9 million rows. Every other rule affects under 0.1%.

**Company extensions underperform three ways.** Null rate 2.9× that of standard
tags. Disproportionately used by smaller filers. And 3,656 of 3,675 tags used
inconsistently across unit types are extensions.

**Amendments arrive about 100 days after the original.** §1.2 inferred 140 by
subtracting medians. §3.1 pairs each amendment to the filing it amends and
measures 98.

**The SEC's documented natural key is incomplete after 2022.** Testing on it gave
4,635,667 violations. Adding `segments` left 154 real ones.

### Filing behaviour and comparables (§3)

**Using restated figures for a historical comparison silently reclassifies one
company in thirty-three.** The same peer comparison, same 3,441 companies, same
fiscal year, built twice: once from what was knowable on 2024-06-30, once from
everything since. 103 companies land in a different quartile. 42 move two or
more, 13 move three. Nothing on the output marks them.

The worst cause is not restatement. It is SIC reclassification. 19 companies
changed industry group and 18 changed quartile materially, nine of them software
and electronics firms that became financial firms after the period. A further 150
companies moved quartile with nothing about them changing, because their peers'
revisions shifted the distribution underneath them.

**Filing promptness shows no drift over twelve quarters.** No series clears
r² = 0.5. Seasonality swings 27 days inside one year against a fitted slope of
zero. And 46% of apparent late filings are not late: 3,856 of 8,371 land inside
the Rule 12b-25 extension window. The honest figure is a range, 6.46% to 11.97%,
and this dataset cannot narrow it because Form 12b-25 carries no XBRL.

### Leakage (§4)

**Computing two features over the whole loaded range instead of as of the filing
date manufactures 0.11 to 0.13 of test AUC.** Same 58,726 filings, same label,
same trivial logistic regression, split on date. Point-in-time scores 0.59 to
0.61. Naive scores 0.72. That is the distance between a weak honest model and one
that reads as a usable screen, and nothing on the output marks it.

One feature does almost all of it. `prior_restatement_count` over the full window
scores 0.7180 alone, higher than the whole fitted naive model, because the
restatement that sets the label is one of the events it counts. Point-in-time the
same feature scores 0.5669 and the model gives it a coefficient of −0.006.

Root causes are labelled established, hypothesised, or not established. None are
confirmed against source filings.

---

## §1 Data quality of SEC XBRL filings

### Scope

SEC Financial Statement Data Sets, 2023 Q1 through 2025 Q4 contains twelve quarterly bulk files.
81,720 filings and 42,797,341 numeric facts loaded into Postgres.
A further 236 rows were discarded at ingestion (see 1.7).

This is not the full history. The SEC publishes these datasets from 2009 Q2; the
range here was chosen to keep the working set on a single machine while
retaining enough time depth for amended filings to appear against their originals.

---

### Coverage

Eight rules were applied, covering five of the standard data quality dimensions.
What was **not** tested matters as much as what was.

| Dimension | Tested | How |
|---|---|---|
| Completeness | Yes | Null values on the numeric fact (DQ-01) |
| Validity | Yes | Duration bounds, date ordering, parseability (DQ-02, DQ-04, DQ-06) |
| Consistency | Yes | Duplicate keys with divergent values (DQ-03); unit of measure mixing (§1.4) |
| Timeliness | Yes | Filing lag against period end (DQ-05, §1.2) |
| Accuracy (internal) | Partial | Balance sheet identity reconciliation (§1.10) |
| Referential integrity | Yes | Every numeric fact joins to a filing **no violations found** |
| Uniqueness | Partial | Tested against the natural key; see §1.6 on the key itself |
| **Accuracy (external)** | **No** | Requires an independent source of truth for the same figures |
| **Semantic correctness** | **No** | Whether a filer chose the *right* tag is not assessable from this data |

Two absences matter.

External accuracy is untested. Nothing in this dataset reveals whether a
reported revenue figure is correct. §1.10 tests one internal identity that must
hold by construction, but confirming accuracy generally would require
reconciling against audited statements or a second commercial data source.

No across filing reconciliation was performed. A figure reported for a
period in one filing is not checked against the same figure reported for that
period in a later filing. That comparison is restatement detection and is the
subject of §2.

---

### Rule definitions

Each rule as an executable predicate, so any figure in this report can be
reproduced without reading the model code.

| ID | Rule | Applied to | Predicate |
|---|---|---|---|
| DQ-01 | Null numeric value | `stg_numeric` | `value is null` |
| DQ-02 | Reporting duration exceeds ten years | `stg_numeric` | `qtrs > 40 or qtrs < 0` |
| DQ-03 | Duplicate key with conflicting values | `stg_numeric` | grouped on the full natural key, `count(*) > 1 and count(distinct value) > 1` |
| DQ-04 | Rejected at load: embedded delimiter | ingestion | field count per row ≠ column count in that file's own header |
| DQ-05 | Filing lag exceeds three years | `stg_submissions` | `filing_lag_days > 1095` |
| DQ-06 | Filed before the period it reports | `stg_submissions` | `filed_date < period_end_date` |
| DQ-07 | Balance sheet identity violation | `dq_balance_sheet_identity` | `abs(assets - liabilities_and_equity) / assets > 0.001` |
| DQ-08 | Mixed unit types on one tag | `dq_unit_inconsistency` | tag used with both currency and non currency units |

The natural key referenced by DQ-02 and DQ-03 is
`(adsh, tag, taxonomy_version, coregistrant, segments, period_end_date, qtrs, unit_of_measure)`.
See §1.6 for how it was established.

Thresholds are stated rather than inherited. `qtrs > 40` (ten years) and
`filing_lag_days > 1095` (three years) are judgement calls chosen to sit clear
of legitimate reporting behaviour. The 0.1% balance sheet bound was chosen from
the observed gap distribution see §1.10.

---

### 1.1 Scorecard

Severity reflects whether a downstream number would be *wrong* (high) or merely
harder to work with (medium).

| Rule | Dimension | Severity | Rows affected | Rows checked | % |
|---|---|---|---|---|---|
| Null numeric value | completeness | High | 1,898,905 | 42,797,341 | 4.437 |
| Reporting duration exceeds ten years | validity | High | 951 | 42,797,341 | 0.0022 |
| Duplicate key with conflicting values | consistency | High | 300 | 42,797,341 | 0.0007 |
| Rejected at load: embedded delimiter | validity | Medium | 236 | 42,797,577 | 0.0006 |
| Filing lag exceeds three years | timeliness | Medium | 59 | 81,720 | 0.0722 |
| Filed before the period it reports | validity | High | 4 | 81,720 | 0.0049 |
| Balance sheet identity violation | accuracy | High | 12 | 156,618 | 0.0077 |

One rule dominates by four orders of magnitude: 4.4% of facts carry no value,
against rates below 0.01% for everything else. That makes the null rate the only
defect large enough to move an aggregate, and the first thing to handle in any
downstream use. The remaining rules matter for a different reason.
The remaining rules are rare enough to survive spot checking unnoticed,
and each produces a specifically wrong answer rather than a missing one.

---

### 1.2 How long until a reported number is public?

`filed − period` measures the gap between a reporting period closing and its
numbers becoming available.

| Form | Filer status | Filings | Median lag (days) | p90 |
|---|---|---|---|---|
| 10-K | Large accelerated | 6,302 | 54 | 60 |
| 10-K | Accelerated | 2,275 | 67 | 76 |
| 10-K | Non-accelerated | 8,927 | 87 | 107 |
| 10-K | *all* | 17,505 | 67 | 103 |
| 10-K/A | *all* | 872 | 207 | 432 |
| 10-Q | Large accelerated | 18,680 | 34 | 39 |
| 10-Q | Accelerated | 6,675 | 38 | 41 |
| 10-Q | Non-accelerated | 27,048 | 44 | 52 |
| 10-Q | *all* | 52,403 | 39 | 46 |
| 10-Q/A | *all* | 977 | 165 | 432 |
| *all forms* | | 71,757 | 43 | 88 |

Filer status is the SEC's own size classification: large accelerated filers have
public float above $700M, accelerated above $75M, non accelerated below.

The median annual report reaches the public 67 days after the period it covers,
and amended annual reports arrive at a median of 207 days. Subtracting the one
median from the other suggests roughly 140 days after the original; **§3.1
supersedes that estimate with a direct pairing and measures 98 days.** The two
medians here are not drawn from the same filings, which is why the subtraction
overstates. Anyone acting on a reported figure therefore carries roughly three
months of exposure before a revision could plausibly exist, with nothing in the
original filing to signal that one is coming. The lag also scales with filer
size, from 54 days for the largest filers to 87 for the smallest, which means
"latest available data" covers a materially different window depending on which
companies are in scope. This measures when filings appeared, not when the
underlying figures were finalised internally.

---

### 1.3 Custom tag usage by company size

XBRL lets filers define company specific extension tags when no standard element
fits. Extensions are permitted and often reasonable, but they do not line up
with any other filer's data.

| Filer status | Companies | Facts | Custom facts | % custom |
|---|---|---|---|---|
| Non-accelerated | 5,292 | 20,847,180 | 2,123,451 | 10.19 |
| Accelerated | 1,370 | 5,112,296 | 372,610 | 7.29 |
| Large accelerated | 2,778 | 16,371,923 | 1,145,149 | 6.99 |

Custom tag usage rises monotonically as filer size falls. A peer comparison
drawn across that gradient is quietly uneven: roughly one line item in ten from
a small filer has no counterpart in anyone else's data, against one in fourteen
for a large one. Why the gradient exists is not tested here; plausible
explanations include less in house taxonomy expertise, weaker analyst pressure
to be comparable, and business models that standard elements genuinely do not
cover. Nothing in this data distinguishes between them.

---

### 1.4 Units of measure

Two distinct phenomena sit under "a tag used with more than one unit", and only
one is a problem.

Multi currency reporting is not an error. Tags such as `Assets` appear under
43 different currency codes because foreign private issuers report in their home
currency. That is correct reporting. It does mean these tags cannot be summed
across filers without FX conversion, a naive aggregate adds yen to euros.

Mixed unit *types* are a different matter. Where one tag carries both
currency and non currency units, it is measuring two different things depending
on who filed it: a share count for one filer, a dollar amount for another.

| Tag | Units used | Non-currency facts |
|---|---|---|
| `NumberOfShareOptionsExercisedInSharebasedPaymentArrangement` | CAD, gal, Option, Options, pure, Share, shares, USD | 419 |
| `SharesToBeIssued` | BRL, CAD, CNY, shares, USD | 91 |
| `WarrantsIssued` | CAD, shares, USD | 36 |
| `ExerciseOfWarrants` | CAD, shares, USD | 34 |
| `Revenue` | 29 currencies plus `pure` | 28 |

Most are ambiguity rather than error. `ExerciseOfWarrants` reasonably means
either how many warrants were exercised or what the exercise was worth, and both
readings are defensible in isolation. A few are simply wrong: `gal` (gallons) on
a share options tag, and `pure` on `Revenue`.

The split by tag type is the substantive finding:

| Tag type | Tags with mixed unit types |
|---|---|
| Company extension | 3,656 |
| Standard taxonomy | 19 |

99.5% of tags used inconsistently across unit types are company specific
extensions. This sharpens 1.3 considerably. Extensions are not merely
incomparable because no one else uses the same name, they are internally
inconsistent about what they measure, so even two filers using the *same*
extension name may not be reporting the same kind of quantity. The standard
taxonomy is close to clean by comparison: 19 cases across 42.8 million facts.

Two limits. Standard tags are not immune. `Revenue` with unit `pure` is one of
the 19. And this join matches on tag name alone, ignoring taxonomy version, so a
name that is custom for one filer and standard elsewhere would be counted once.

---

### 1.5 Missing values

1,898,905 of 42,797,341 facts (4.44%) have a tag, a period, and a unit but no
value. This is the largest defect in the report by four orders of magnitude, and
the only one big enough to move an aggregate.

Abstract tags are not the explanation. These are presentation only section
headers that carry no value by design and would have diluted the rate if
present. None appear in the fact table at all. They are abstract elements
that live in the presentation file, not the numeric one. The 4.44% needs no adjustment.

Custom tags carry a substantially higher proportion of null values than
standard ones:

| Tag type | Facts | Nulls | % null |
|---|---|---|---|
| Standard taxonomy | 39,058,779 | 1,488,920 | 3.81 |
| Company extension | 3,738,562 | 409,985 | 10.97 |

Company specific extensions carry a null rate 2.9 times that of standard
taxonomy elements. Extensions are 8.7% of facts but 21.6% of nulls. This is the
third distinct way extensions underperform, after non comparability (§1.3) and
unit type inconsistency (§1.4), a filer defining its own element is more likely
to leave it empty than to leave a standard one empty.

The rate is also concentrated by filer. Several companies in §1.11 report
null rates above 40%. HYPERSCALE DATA is at 42.1%. FOXO TECHNOLOGIES is at 40.7%.
PROPANC BIOPHARMA is at 40.4%. These values are against the 4.44% population rate.
The defect is driven by a subset of filers rather than spread evenly across the source.

*Root cause: not established.* The candidates are a filer tagging a line
item that does not apply to the period, an extraction failure in the SEC's own
processing, or elements functioning as headers without carrying the abstract
flag. The extension correlation is consistent with the first, since a
company defined element has no external validation of whether a value is
required, but nothing here tests that.

The practical consequence holds regardless of cause: any consumer treating
missing as zero understates 1.9 million line items. Because the defect
concentrates in extensions and in specific filers, a targeted filter is more
efficient than a blanket one.

### 1.6 Conflicting duplicate values

The natural key of a numeric fact is
`(adsh, tag, version, coreg, segments, ddate, qtrs, uom)`. 154 key groups
covering 300 rows appear more than once *within a single filing*, each time with
two different values.

They concentrate in two derivative disclosure tags,
`DerivativeLiabilityNotionalAmount` and `DerivativeAssetFairValueGrossLiability`,
and in a small number of filers.

Duplicate keys with identical values would be harmless redundancy. These are
not: every one of the 154 groups carries two distinct values, so a query
selecting one row per key returns a different answer depending on physical row
order, with no ordering guarantee to appeal to. The same query run twice can
disagree.

Establishing the key is worth recording. The SEC documents the primary key
without `segments`; testing on that basis produced 4,635,667 violations. Adding
`segments` reduced it to 154, which is how the documented key was found to be
incomplete for post 2022 data, and is itself a finding about the published
specification rather than the data.

---

### 1.7 Rows rejected at ingestion

236 rows across the twelve quarters could not be loaded. Each contains a literal
tab character inside a free text field, producing more fields than the file's
own header declares.

Such a row cannot be repaired reliably, because there is no way to know which
field the stray tab split, so it is rejected and counted rather than silently
dropped or half parsed.

| Quarter | Rejected | | Quarter | Rejected |
|---|---|---|---|---|
| 2023q1 | 10 | | 2024q3 | 31 |
| 2023q2 | 10 | | 2024q4 | 20 |
| 2023q3 | 0 | | 2025q1 | 30 |
| 2023q4 | 12 | | 2025q2 | 26 |
| 2024q1 | 9 | | 2025q3 | 48 |
| 2024q2 | 18 | | 2025q4 | 22 |

The count rises across the period, from around 10 per quarter in 2023 to 20-48
in 2025. With a maximum of 48 in a quarter of roughly 3.7 million rows, this is
too small a sample to call a trend with confidence, and no mechanism is tested
here. It is recorded because the alternative, dropping the rows without
counting them, would leave the loss invisible.

---

### 1.8 Issue register

Detection without disposition is only half of a data quality process. Each rule
below carries a root cause where one is established, an honest label where it is
not, and a recommended action for a downstream consumer of this data.

The **remediable by** column matters more than it might appear. These defects
divide into three groups: those a consumer can handle in their own pipeline,
those only the publisher (the SEC) could fix, and those originating with the
filer and correctable only by them. Recommending "fix the data" for an issue you
do not own is not a recommendation.

| ID | Issue | Severity | Rows | Materiality | Remediable by |
|---|---|---|---|---|---|
| DQ-01 | Null numeric value | High | 1,898,905 | **High:** the only defect large enough to move an aggregate | Consumer |
| DQ-02 | Reporting duration exceeds ten years | High | 951 | **Medium:** low volume, but each instance is nonsense if aggregated | Consumer |
| DQ-03 | Duplicate key with conflicting values | High | 300 | **Medium:** produces non deterministic query results | Consumer |
| DQ-04 | Rejected at load: embedded delimiter | Medium | 236 | **Low:** negligible volume, but invisible if not counted | Publisher |
| DQ-05 | Filing lag exceeds three years | Medium | 59 | **Low:** distorts timeliness benchmarks only | Consumer |
| DQ-06 | Filed before the period it reports | High | 4 | **Low:** negligible volume, but undermines trust in the date fields | Filer |

---

**DQ-01: Null numeric value**

*Root cause: not established.* Candidates are a filer tagging an element that
does not apply to the period, an extraction failure in the SEC's processing, or
elements acting as headers without carrying the abstract flag. Distinguishing
them requires checking whether nulls cluster by tag, by filer, or by quarter.

*Recommended action:* never coerce null to zero. Filter these rows explicitly at
the point of aggregation and report the excluded count alongside any total, so a
missing figure is visible rather than silently absorbed. Investigate clustering
before deciding whether imputation is ever appropriate.

**DQ-02: Reporting duration exceeds ten years**

*Root cause: partially established.* `qtrs` values in the mid range are
plausible for inception to date reporting by development stage companies. The
extremes are not, as the maximum observed is 3,604 quarters, or 901 years, which
no reporting basis produces.

*Recommended action:* apply a ceiling at ingestion. `qtrs > 40` excludes any
duration beyond ten years and removes all 951 rows. Document the threshold
rather than tuning it silently; a consumer analysing development stage filers
may legitimately want a higher bound.

**DQ-03: Duplicate key with conflicting values**

*Root cause: not established.* Concentrated in derivative disclosures and in a
small number of filers, which suggests a filer side tagging process rather than
a systematic publisher issue, but nothing here tests that.

*Recommended action:* do not deduplicate by arbitrary selection. Picking one of
two conflicting values makes the result depend on physical row order. Either
exclude both rows and flag the key as unresolved, or escalate to the filing
itself for manual resolution where the figure is material to the analysis.

**DQ-04: Rejected at load: embedded delimiter**

*Root cause: established.* Free text fields in the SEC's published files contain
literal tab characters, producing more fields than the file's own header
declares. This is a defect in the published artefact, not in what companies
reported.

*Recommended action:* retain the current handling. Reject the row, count it,
and surface the count. The row cannot be repaired reliably because there is no
way to determine which field the stray tab split. An institutional consumer
would raise this with the publisher; a downstream analyst can only ensure the
loss is measured rather than silent.

**DQ-05: Filing lag exceeds three years**

*Root cause: hypothesised.* Consistent with delinquent filers submitting for
long past periods after a gap in reporting, though this is inferred from the lag
distribution rather than verified against filer history.

*Recommended action:* exclude from any timeliness benchmark, since these filings
describe a different behaviour from ordinary reporting and would distort a
median or percentile. Retain them for completeness and coverage analysis, where
a late filing is still a filing.

**DQ-06: Filed before the period it reports**

*Root cause: not established.* Four filings carry a filing date earlier than the
period end they report on, which is not possible under normal reporting.

*Recommended action:* exclude from lag calculations and flag. The volume is
negligible, but the implication is not: it demonstrates that `filed` and
`period` cannot be assumed internally consistent, and any pipeline computing a
difference between them should validate the sign rather than trust it.

---

What is not covered here. No root cause is confirmed by inspection of source
filings; all are inferred from the aggregate data. No estimate of financial
materiality is offered, since that would require assumptions about downstream
use that this analysis does not make. Remediation ownership is assigned on where
the defect originates, not on any formal data ownership model.


---

---

### 1.9 Verification

A finding is a query result until someone inspects it. Instances of the three
high severity event based rules were sampled and reviewed individually.

| Rule | Population | Sampled | Confirmed | Uncertain |
|---|---|---|---|---|
| DQ-06 Filed before period end | 4 | 4 | 4 | 0 |
| DQ-02 Duration exceeds ten years | 951 facts | full population by band | 15 | 936 |
| DQ-03 Conflicting duplicates | 154 groups | 20 | 20 | 0 |

DQ-06: all four confirmed, and none are ordinary filings. PowerSchool
Holdings filed a 10-Q on 2024-05-07 for a period ending 2024-12-31, 238 days in
the future; Power REIT the same, 235 days. The other two (an S-4/A registration
amendment and a 6-K foreign issuer report) are not periodic reports at all.
In every case `period` carries a fiscal year end that had not yet
occurred rather than the period actually reported on. The defect is real, but it
is better described as a field semantics problem than a date error: 'period'
does not always mean what a consumer would assume.

DQ-02: the threshold is too aggressive and most flagged rows are probably
legitimate. Splitting the 951 facts by duration:

| Duration band | Facts | Filings |
|---|---|---|
| 41–80 quarters (10–20 years) | 733 | 341 |
| 81–200 quarters | 203 | 61 |
| 200+ quarters | 15 | 2 |

The 41–80 band is 77% of the population and spread across 341 filings, which is
consistent with inception to date reporting by development stage companies, a
legitimate basis that genuinely produces multi decade durations. Only the 200+
band, 15 facts across 2 filings, is unambiguously defective; the extreme case
claims 3,604 quarters, or 901 years.

This is a false positive finding against one of this report's own rules. The
`qtrs > 40` bound was chosen to sit clear of normal reporting, and it does,
but it does not sit clear of *unusual but valid* reporting. A consumer wanting
only genuine defects should use a far higher bound. The rule as stated is
retained, with this caveat, rather than silently retuned.

DQ-03: all twenty confirmed, and the gaps are not rounding. The sampled
groups show differences up to 9,000%, and in most cases the two values carry
**opposite signs**: −91,000 against −1,000, −168,000 against +2,000, −4,969,000
against +301,000. These are not precision artifacts. A consumer selecting either
row gets not merely a different magnitude but a different direction.

The sample is also heavily concentrated. Nearly all twenty come from a single
filer (CIK prefix `0001918712`) on a single tag,
`DerivativeAssetFairValueGrossLiability`. That narrows the root cause
considerably: this looks like one company's derivative disclosure process rather
than a systemic tagging problem, which is consistent with the concentration
result in §1.11.

What verification did not cover. The rate based rules (DQ-01 nulls, custom
tag share) were not sampled, since "is this row genuinely null" is not a
judgement an inspection can improve on. Verification was against the loaded data,
not against the original filings on EDGAR. A row that is internally implausible
may still faithfully reproduce what the filer submitted, and distinguishing those
would require fetching the source documents.

---

### 1.10 Balance sheet reconciliation

Every other rule tests whether a value is present, plausible, or unambiguously
keyed. None test whether it is *right*. One internal identity can be checked
without an external source: assets must equal liabilities plus equity.

166,270 consolidated balance sheets were assembled across 8,252 companies.
156,618 (94.2%) carry the filer's own reported
`LiabilitiesAndStockholdersEquity` total and can be tested directly.

The threshold comes from the gap distribution:

| Gap band | Filings |
|---|---|
| exact | 156,492 |
| < 0.00001% | 19 |
| 0.00001–0.0001% | 31 |
| 0.0001–0.001% | 43 |
| 0.001–0.01% | 15 |
| 0.01–0.1% | 3 |
| 0.1–1% | 3 |
| > 1% | 12 |

The distribution is bimodal. 108 filings sit below 0.1%, consistent with
rounding at the precision filers actually report. Counts then collapse to 3 and
3 before rising again to 12 above 1%. That gap is the natural break, so 0.1% is
the materiality bound which was chosen from the observed shape rather than picked in
advance.

99.92% of testable balance sheets balance exactly. This is the first rule
where the data overwhelmingly passes, in a report otherwise listing defects.

Twelve filings exceed the threshold. **All twelve are non accelerated filers.**
The largest is a shell sized balance sheet reporting $5 in assets against $5,379
in liabilities and equity. One company, NEXT MEATS HOLDINGS, appears twice:
a 10-Q and its own 10-Q/A amendment carry the identical imbalance. The
amendment did not correct it.

A check that does not work. The same identity can be tested by summing
components (`Assets = Liabilities + StockholdersEquity`) rather than using the
filer's reported total. That form produces roughly 50,000 apparent failures
against 12 from the reported total form. Two explanations were tested:
non controlling interests account for 3,487 cases, and mezzanine equity for a
further 273. Together they explain about 7%.

The remainder is unexplained. The most likely cause is that `Liabilities` is not
consistently tagged as a grand total. Many filers tag current and non-current
liabilities separately without a roll-up, but that was not tested. The
components form is therefore not used, and the finding is recorded as a
methodological result: a naive two-term implementation of this identity would
report a defect rate four orders of magnitude too high.

Three limits apply. Consolidated USD figures only; segment and subsidiary
breakdowns are excluded because they do not balance independently. Form types
are not filtered, so two proxy statements appear among the twelve. Where a tag
appears twice within a filing with conflicting values (DQ-03), one is selected
arbitrarily.

---

### 1.11 Concentration

Counts say how much; they do not say whether a defect is systemic. Six rules
were evaluated per filer across 8,693 filers: two rate based, flagged at twice
the population rate, and four event based, flagged on any occurrence.

| Rules failed | Filers | % of filers |
|---|---|---|
| 0 | 6,010 | 69.1 |
| 1 | 2,342 | 26.9 |
| 2 | 338 | 3.9 |
| 3 | 3 | 0.03 |

Defects are concentrated, not systemic. Seven filers in ten fail nothing.
Only three of 8,693 fail three or more rules. This is a minority of filers
problem, which makes filer level screening a more effective remediation than
blanket filtering. This is a materially different recommendation from what the raw
counts alone would suggest.

Quality also grades with filer size:

| Filer status | Filers | Mean rules failed | Failing 3+ |
|---|---|---|---|
| Non-accelerated | 4,901 | 0.54 | 3 |
| Accelerated | 1,069 | 0.10 | 0 |
| Large accelerated | 2,535 | 0.07 | 0 |

Non accelerated filers fail roughly eight times as many rules as large
accelerated filers. This is the fourth independent measure pointing at the same
population, after extension tag share (§1.3), unit type inconsistency (§1.4),
and every balance sheet violation (§1.10). Four different checks, four times the
same answer.

The three filers failing three rules are REGEN BIOPHARMA, THERAPEUTIC
SOLUTIONS INTERNATIONAL, and NEXT MEATS HOLDINGS. All are non accelerated.
NEXT MEATS also appears in §1.10, failing an independent accuracy check as
well as the completeness and comparability ones.

Null rates among the worst filers are extreme: 42.1% at HYPERSCALE DATA, 40.7%
at FOXO TECHNOLOGIES, 40.4% at PROPANC BIOPHARMA, against a 4.44% population
rate. This substantially qualifies §1.5. The missing value problem is driven by
a subset of filers rather than spread evenly.

One filer breaks the pattern. PENNANTPARK FLOATING RATE CAPITAL is large
accelerated and fails two rules, but on conflicting duplicate keys rather than
the null and extension profile that characterises the rest. A different failure
mode entirely.

Three caveats. The two rate thresholds, twice the population null rate, and
20% custom tags, are chosen, not derived from the distributions. Event based
rules flag on a single occurrence, so a filer with one bad row ranks alongside
one with hundreds. Most importantly, the six rules are **not independent**:
custom tag usage and unit inconsistency measure related behaviour, so a filer
failing both has not necessarily failed two distinct things. The summed score
should be read as a rough ordering, not a measure.

---

## §2 Restatements (Stage 2)

**Report date:** 2026-08-30
**Models:** `int_restatements`, `rst_by_sector`, `rst_magnitude_distribution`,
`rst_by_statement`, `rst_clustering`, `rst_amendment_chains`, `rst_serial_restaters`
**Rebuild gate:** `dbt run -s int_restatements` re-executed 2026-08-30 returned
426,706 rows and checksum `75d3b426769dfb0ccc5b0e7574df5388`, identical to the
shipped table.

### Scope

§1 tested each filing against itself. §2 tests filings against each other.

`int_restatements` compares one described fact across every filing that reported
it. A described fact is the partition key:

```
(cik, coregistrant, segments, tag, period_end_date, qtrs, unit_of_measure)
```

ordered by `filed_date`. `adsh` is deliberately absent. Comparing across
filings is the entire mechanism. `taxonomy_version` is also absent, because the
same concept under `us-gaap/2023` and `us-gaap/2024` is one fact, and for a
company extension tag the taxonomy version *is* the accession number, so
including it would put every extension in a partition of one and hide every
restatement of one.

Three columns in that key are false positive guards rather than identity.
`segments` prevents a segment level figure being compared against the
consolidated total; `coregistrant` prevents a subsidiary's figure being compared
against its parent's; `qtrs` and `unit_of_measure` prevent a quarterly figure
being compared against an annual one, or dollars against shares. They are not
cosmetic. Measured on the loaded range, holding the method fixed (first value
against latest, 0.1% threshold, facts reported on more than one date):

| Partition key | Revisable facts | Restated | % |
|---|---|---|---|
| `cik, tag, period_end_date, qtrs, unit_of_measure` | 4,940,317 | 346,589 | 7.02 |
| &nbsp;&nbsp;+ `coregistrant` | 5,037,163 | 347,446 | 6.90 |
| &nbsp;&nbsp;+ `segments` (shipped) | 8,918,472 | 426,706 | **4.785** |

`segments` does nearly all the work, and the mechanism is visible in the
columns: adding it splits coarse groups apart, raising the denominator by 77%
while raising the numerator by only 23%. Omitting it would have inflated the
headline rate by 1.44×, because a segment level figure would be compared against
the consolidated total and the difference read as a revision. `coregistrant`
barely moves the rate. It is cheap correctness rather than a large effect.

The rounding threshold is 0.001, **one tenth of one percent** of the first
reported value, set in `dbt_project.yml` as
`restatement_rounding_threshold`. A later value differing from the first by less
than that is treated as a change in reported precision rather than a
restatement. It matches the bound §1.10 used for the balance sheet identity.
Unlike that one it is **a judgement call, not a bound derived from a
distribution** §2.8 gives the sensitivity and §2.7 shows the false positives it
fails to catch.

A fact reported at zero and later at a non zero value has no denominator and is
material by fiat: there is no ratio to test, and a figure that was zero and is
now not zero is a change of kind rather than of precision. 6,950 restatements
(1.6%) are of this form.

8,918,472 described facts were reported on more than one date and
so could have been revised. 426,706 of them were, across 7,544 of 8,693 companies
(86.8%) and 15,438 distinct tags. **The restatement rate is 4.785%** the low
single-digit figure the design predicted, against the 16% that the incomplete key
would have produced.

---

### One result organises the rest

**Only 8.26% of restatements arrive in an amendment.** Of the 426,706 revisions,
35,225 were carried by a form ending in `/A`. The other 391,481 arrived inside an
ordinary next-period filing, a 10-Q or 10-K quietly carrying a revised
comparative, with no amendment marker of any kind.

| Revising form | Restatements | % | Median days from first report |
|---|---|---|---|
| 10-Q | 224,074 | 52.51 | 364 |
| 10-K | 96,883 | 22.70 | 364 |
| 20-F | 35,843 | 8.40 | 366 |
| 10-Q/A | 14,524 | 3.40 | 156 |
| 6-K | 12,522 | 2.93 | 354 |
| 10-K/A | 11,126 | 2.61 | 307 |
| S-1 | 8,798 | 2.06 | 156 |
| 8-K | 6,111 | 1.43 | 133 |
| S-1/A | 5,582 | 1.31 | 101 |
| 40-F | 3,215 | 0.75 | 364 |

The median revision arrives **364 days** after the figure was first published
(p25 239, p75 368, p90 398). Only 13.1% arrive within 100 days. That tight
clustering on one year is the mechanism: most revisions are not corrections
announced as such, they are last year's number re-presented as this year's
comparative.

This substantially revises §1.2. That section measured amendment lag (a median
207 days for a 10-K/A, roughly 140 days after the original) and concluded a
consumer has months of exposure before a revision could exist. The exposure is
worse than that. **Watching for amendments catches roughly one restatement in
twelve.** The other eleven require comparing a figure against the same figure in
the next annual filing, a year later, in a document that announces nothing.

*Root cause: established.* The 364-day median, the concentration in 10-Q and
10-K rather than `/A` forms, and the annual-comparative mechanism are all
directly observable in the report sequences and mutually consistent.

---

### 2.1 Which sectors restate most

Do some industries revise their reported figures more than others, once size
is accounted for? `rst_by_sector` maps SIC codes to divisions and two-digit
major groups, then aggregates over `GROUPING SETS` at both levels plus a grand
total. Sector is taken from the `dim_company` SCD2 version current at
`first_filed_date`. The industry the company reported from when the original
number was published, never its present-day SIC. Both the numerator and the
denominators use that same as-at rule, so a reclassification cannot move a
restatement into a sector whose denominator never carried the fact. The
denominator is revisable facts, not filings: a large sector restates more by
filing more, and dividing by exposure is what makes the sectors comparable.

| Sector | Restatements | Revisable facts | % restated | Companies restating | % downward | Median revision |
|---|---|---|---|---|---|---|
| Agriculture, Forestry & Fishing | 3,510 | 51,040 | 6.877 | 92.86 | 62.74 | 58.5% |
| Manufacturing | 153,975 | 2,663,472 | 5.781 | 89.27 | 62.49 | 52.7% |
| Services | 76,916 | 1,352,516 | 5.687 | 86.70 | 59.50 | 42.7% |
| Wholesale Trade | 7,491 | 143,499 | 5.220 | 85.29 | 58.27 | 30.7% |
| Retail Trade | 16,697 | 326,942 | 5.107 | 91.35 | 56.67 | 36.9% |
| Transport, Comms & Utilities | 33,155 | 678,871 | 4.884 | 89.13 | 53.19 | 38.1% |
| Mining | 16,665 | 353,385 | 4.716 | 86.96 | 53.41 | 38.3% |
| Finance, Insurance & Real Estate | 101,291 | 2,323,787 | 4.359 | 79.66 | 52.27 | 30.1% |
| Construction | 3,442 | 83,770 | 4.109 | 82.65 | 53.25 | 32.4% |
| Unclassified (no SIC) | 13,564 | 941,190 | 1.441 | 87.79 | 52.51 | 75.0% |
| **All sectors** | **426,706** | **8,918,472** | **4.785** | **86.78** | **57.76** | **42.4%** |

Excluding the unclassified bucket, sector rates run from 4.11%
(Construction) to 6.88% (Agriculture), a spread of 1.7×. At major-group level
the spread widens to 3×, from 2.81% (major group 42, trucking and warehousing) to
8.60% (major group 14, mining of nonmetallic minerals).

The sector effect is real but modest, and it is much weaker
than §1's filer-size effect on data quality, which ran to 8×. Industry is not a
useful screen on its own: every division restates between 4% and 7% of its
revisable facts, and no sector is clean. Two secondary patterns are more usable
than the ranking. Finance, Insurance & Real Estate has both the second-lowest
rate (4.36%) and by far the lowest share of companies restating at all (79.66%
against 86.78% overall), so its restatements concentrate in fewer filers.
Manufacturing and Agriculture revise downward most often (62%), against 52% for
Finance, restatements in the goods-producing sectors are disproportionately
reductions.

The unclassified bucket is an artefact and should not be read as a sector.
Its 1.441% rate is the lowest in the table by 3×, and the cause is the
denominator, not clean reporting: 941,190 revisable facts across only 213
companies, roughly 4,400 each against 861 for Manufacturing. All 13,564 of its
restatements come from companies with a null SIC in the source data, and the
largest are business development companies and private credit funds: Golub
Capital BDC, StepStone Private Credit, Franklin BSP, HPS Corporate Lending, Ares
Capital. These file per-holding investment schedules at segment grain, producing
enormous numbers of revisable facts that are re-reported each quarter and rarely
change. The bucket measures a reporting style, not an industry.

*Root cause of the sector gradient: not established.* Candidates are genuine
differences in estimation difficulty (percentage-of-completion, inventory
valuation and biological assets are all harder than interest accruals), differing
audit intensity, and differing filer-size mix within sectors. Nothing tested here
separates them.

---

### 2.2 How large are revisions

When a figure is revised, by how much, and does the revision run in a
systematic direction?

`rst_magnitude_distribution` buckets every restatement
twice over: `width_bucket` on a linear 5-point scale from 0 to 100% of the
original value, and again on a log10 scale by decade, because the observed spread
runs from a tenth of a percent to thirteen orders of magnitude above it and a
linear axis alone puts three quarters of the mass in the first few bins.
Direction is carried as a dimension rather than a filter, so a directional bias
shows up as a shape difference. `percentile_cont` gives the spread. The 6,950
zero-denominator restatements are carried in their own bucket rather than dropped,
so the buckets reconcile against the source table.

| | Median | p75 | p90 | p99 | Restatements |
|---|---|---|---|---|---|
| All | 42.4% | 100.0% | 300.1% | 99,900% | 419,756 |
| Downward | 46.4% | 99.0% | 200.0% | 9,900% | 244,654 |
| Upward | 36.7% | 200.0% | 686.2% | 99,900% | 175,102 |

Median **signed** revision across all restatements: **−1.80%**.

The linear histogram is bimodal, which is the substantive shape:

| Band | Restatements | % |
|---|---|---|
| 0–5% | 106,132 | 25.28 |
| 5–10% | 30,984 | 7.38 |
| 10–50% | 81,810 | 19.49 |
| 50–90% | 43,363 | 10.33 |
| 90–95% | 14,499 | 3.45 |
| 95–100% | 29,899 | 7.12 |
| >100% | 113,069 | 26.94 |

The median revision is 42.4% of the original figure. A quarter of
all restatements fall in the 0–5% band, and another quarter exceed 100%.

Two things here, and the second is more important than the first.

First, **restatements skew downward, but only slightly.** 57.76% are reductions
and the median signed revision is −1.80%. The direction asymmetry is real and
consistent across sectors, but it is nothing like a systematic overstatement
story, the upward tail is actually the heavier one (p90 686% against 200%).

The skew is **not** manufactured by the contaminated rows, and §2.7 tests that
directly. Sign flips carry an identical magnitude either side, so their direction is
meaningless; excluding all 29,118 of them leaves 58.51% downward. Excluding the
zero-origin and extreme-magnitude categories as well leaves **60.02%**. Both of
those classes are strongly upward on their own (74% and 76% respectively), so they
were diluting this finding rather than producing it. The cleaner the population,
the stronger the downward skew.

Second, **the median of 42.4% is far too large to be read as "the typical
correction is 42% wrong", and reading it that way would be a mistake.** The mass
above 90% is not made of near-total corrections. §2.7 identifies what it is:
retroactive reverse split re-presentation of share counts (a 1-for-15 split
reports as a 93.3% reduction), exact power of ten scale changes, and IAS 29
hyperinflation re-presentation by Argentine issuers. The bimodality is the
signature of two different populations sharing one table, genuine corrections
concentrated in the 0–10% bands, and re-presentations concentrated above 90%.

Anyone using this distribution should read the **0–5% band as the corrections
distribution** and treat everything above 90% as requiring case-by-case
classification.

*Root cause of the bimodality: established.* Sampling in §2.7 and the
population-level tests there confirm the upper mode is dominated by
re-presentation rather than correction.

---

### 2.3 Which line items get revised

Do revisions concentrate on particular financial statements, or on particular
line items? `rst_by_statement` joins restatements to `dim_tag` for statement
placement. `int_restatements` is keyed on `tag` without `taxonomy_version`
while `dim_tag` is keyed on both, so the dictionary is first collapsed to tag
grain by modal statement across the versions that define the tag; a tag placed
on more than one statement is flagged (`placement_is_ambiguous`) rather than
quietly assigned. Denominator is again revisable facts, so a tag reported on
every filing does not accumulate restatements by exposure alone. Statement and
grand totals are computed over every tag; only the tag-level detail is trimmed
to the top 15, so a total is never the sum of the rows displayed beneath it.

| Statement | Restatements | Revisable facts | % restated | Distinct tags | Companies | % downward | Median revision |
|---|---|---|---|---|---|---|---|
| Income statement | 162,517 | 2,230,383 | **7.287** | 11,771 | 5,611 | 60.80 | 26.3% |
| Cash flow | 91,851 | 2,125,699 | 4.321 | 52,252 | 5,978 | 53.09 | 39.4% |
| Balance sheet | 78,290 | 1,834,082 | 4.269 | 17,350 | 6,138 | 54.89 | 31.4% |
| Equity | 74,623 | 1,761,520 | 4.236 | 29,922 | 4,967 | 61.22 | 94.3% |
| Comprehensive income | 10,787 | 297,991 | 3.620 | 2,057 | 1,486 | 52.22 | 44.4% |
| Unclassified | 1,034 | 34,616 | 2.987 | 1,498 | 150 | 48.84 | 75.0% |
| Supplementary information | 7,604 | 634,181 | **1.199** | 895 | 200 | 53.76 | 84.3% |
| **All statements** | **426,706** | **8,918,472** | **4.785** | **115,745** | **7,544** | **57.76** | **42.4%** |

Most-revised individual tags:

| Tag | Statement | Restatements | % of revisable | Companies | Median revision |
|---|---|---|---|---|---|
| `RevenueFromContractWithCustomerExcludingAssessedTax` | IS | 19,898 | 6.49 | 1,206 | 12.2% |
| `StockholdersEquity` | EQ | 15,065 | 4.33 | 2,051 | 64.3% |
| `Revenues` | IS | 9,603 | 7.26 | 801 | 14.3% |
| `OperatingIncomeLoss` | IS | 9,597 | 9.89 | 1,479 | 17.6% |
| `NetIncomeLoss` | CF | 8,912 | 4.98 | 1,417 | 22.9% |
| `EarningsPerShareBasic` | IS | 8,086 | **10.48** | 1,700 | 300.0% |
| `EarningsPerShareDiluted` | IS | 7,741 | **10.55** | 1,718 | 200.0% |
| `WeightedAverageNumberOfSharesOutstandingBasic` | IS | 6,317 | 9.36 | 1,340 | 95.0% |
| `SharesOutstanding` | EQ | 5,844 | 9.73 | 1,048 | 95.5% |
| `Assets` | BS | 4,808 | 7.04 | 1,462 | 6.9% |

The income statement is revised at **7.29%** of revisable facts,
1.7× the balance sheet's 4.27% and 6× supplementary information's 1.20%.

Revisions concentrate on the statement people actually read.
The income statement is the most revised, and within it the most-revised items are
the headline ones: revenue, operating income, and earnings per share. Earnings per
share is the single most frequently revised concept in the dataset at 10.5% of
revisable facts, one in ten reported EPS figures is later published at a
different value. Balance sheet items are comparatively stable, and `Assets`
specifically is revised at 7.04% but with a median revision of only 6.9%, the
smallest of any major tag.

Two caveats on this table, both material:

The EPS medians of 200–300% are a small-denominator effect, not a measure of
error size. Median first reported EPS among restated facts is $0.41 and the
median absolute change is $0.965, so a swing from $0.41 to −$0.55 registers as a
235% revision. EPS percentages are not comparable with revenue or asset
percentages and should not be pooled with them. The *frequency* (10.5%) is sound;
the magnitude is not.

The ~95% medians on share-count tags are reverse splits. See §2.7: 47% of
share-denominated restatements carry a near-integer shrink ratio, against a 2.45%
base rate on USD facts.

Cash flow carries 52,252 distinct tags against the income statement's 11,771,
which is a comparability finding in itself and consistent with §1.3: the cash flow
statement is where filers extend the taxonomy most heavily.

*Root cause: hypothesised.* The income statement's higher rate is consistent with
it carrying more estimates and more subtotals that shift when any component moves,
where balance sheet items are more often directly measured. Not tested here.

---

### 2.4 Do restatements cluster in time

Do revisions bunch into particular quarters, or arrive at a steady rate?

`rst_clustering` asks the question on two clocks, because
"when" is ambiguous here: the quarter a revision was *published*, and the quarter
whose figures it *revised*. Each carries its own denominator (publication
divides by filings published that quarter, the period clock by revisable facts
describing that period) since a raw count would only rediscover that more filings
arrive in 10-K season. A quarter spine from `dim_date` keeps empty quarters
present so the trailing average is a genuine time window, and the four-quarter
trailing window excludes the current quarter so a spike is measured against the
level before it rather than a baseline it is itself inflating.

**Publication clock:**

| Quarter | Restatements | Filings | Per 1k filings | vs 4-quarter trailing rate |
|---|---|---|---|---|
| 2023 Q1 | 1,418 | 6,754 | 210.0 | n/a |
| 2023 Q2 | 13,341 | 8,039 | 1,659.5 | 7.90 |
| 2023 Q3 | 13,928 | 7,067 | 1,970.9 | 2.11 |
| 2023 Q4 | 19,034 | 6,882 | 2,765.8 | 2.16 |
| 2024 Q1 | 49,209 | 6,028 | 8,163.4 | 4.94 |
| 2024 Q2 | 50,724 | 7,675 | 6,609.0 | 1.82 |
| 2024 Q3 | 44,981 | 6,699 | 6,714.6 | 1.38 |
| 2024 Q4 | 51,195 | 6,491 | 7,887.1 | 1.30 |
| 2025 Q1 | 49,408 | 6,231 | 7,929.4 | 1.08 |
| 2025 Q2 | 44,803 | 7,009 | 6,392.2 | 0.88 |
| 2025 Q3 | 43,181 | 6,541 | 6,601.6 | 0.91 |
| 2025 Q4 | 45,484 | 6,304 | 7,215.1 | 1.00 |

From 2024 Q2 onward the rate holds between 6,392 and 7,929 per
1,000 filings, a band of −9% to +12% around a mean of 7,050. The apparent 39×
ramp from 2023 Q1 to 2024 Q1 is **not a finding: it is the detector warming
up.**

Restatements do not cluster, and the section's main result is a negative one.
A revision can only be observed if the original report is also inside the
loaded window. In 2023 Q1 there is no prior data at all, so almost nothing *can* register as a
revision; by 2024 Q1 there is a full year of originals to revise. The
`count_vs_trailing` ratio of 4.94 at 2024 Q1 would read as a dramatic spike to
anyone taking the column at face value, and it is entirely an artefact of a
trailing window that spans the ramp. **The first four quarters of this series
must be discarded.** Once they are, restatements do not cluster: they arrive at a
steady rate.

**Period clock**, over the range where both series are populated:

| Period quarter | Restatements | Revisable facts | Per 1k facts |
|---|---|---|---|
| 2022 Q4 | 74,335 | 1,332,198 | 55.8 |
| 2023 Q1 | 32,281 | 574,237 | 56.2 |
| 2023 Q2 | 44,045 | 779,393 | 56.5 |
| 2023 Q3 | 41,432 | 762,633 | 54.3 |
| 2023 Q4 | 56,498 | 1,290,237 | 43.8 |
| 2024 Q1 | 28,725 | 545,918 | 52.6 |
| 2024 Q2 | 37,992 | 738,876 | 51.4 |
| 2024 Q3 | 33,276 | 718,628 | 46.3 |
| 2024 Q4 | 16,442 | 702,916 | 23.4 |
| 2025 Q1 | 3,615 | 129,731 | 27.9 |
| 2025 Q2 | 2,599 | 118,909 | 21.9 |
| 2025 Q3 | 402 | 22,277 | 18.0 |

The period clock makes the same point from the other end. Raw counts spike
violently on annual period-ends, 2022 Q4 carries 74,335 restatements, 5.9× its own four-quarter
trailing average and eight times the 9,343 of the quarter before, but the *rate*
does not rise at all, 55.8 per 1,000 against 61.9. **The count spikes are annual-comparative volume, not
restatement clustering.** The denominator is what separates them, and without it
this model would have reported a Q4 restatement season that does not exist.

The decline from 2024 Q4 onward is right-censoring, quantified in §2.8.

A handful of period quarters fall in 2026 and 2027, beyond the end of the data.
These are the §1.9 DQ-06 cases: `period` carrying a fiscal year end that has not
yet occurred rather than the period actually reported on. They total 11
restatements and are left in place rather than filtered, since §1 established the
field semantics problem is real.

*Root cause of the flat rate: established.* Both clocks, with independent
denominators, agree that the rate is stable once censoring is excluded.

---

### 2.5 Does one restatement predict another

Given that a figure has been revised once, is it more likely to be revised
again? `int_restatements` compares first value against latest, which collapses
a fact revised three times into a single row, it cannot answer this question.
`rst_amendment_chains` rebuilds the full report sequence and walks it with a
**recursive CTE**: each link is a material change from the *previous* report
rather than from the first, so a fact revised three times becomes one chain of
length three. The recursion carries the accession path and the value the chain
started from, neither of which a plain aggregate over the steps could produce
in order. The same collapse-and-tiebreak rule as `int_restatements` is used,
so a chain cannot count a revision the restatement model does not recognise.

| Chain length | Chains | Companies | Median span (days) |
|---|---|---|---|
| 1 | 406,726 | 7,525 | 362 |
| 2 | 28,183 | 4,186 | 363 |
| 3 | 4,709 | 1,288 | 409 |
| 4 | 1,104 | 447 | 422 |
| 5 | 179 | 104 | 406 |
| 6 | 72 | 33 | 354 |
| 7 | 32 | 14 | 483 |
| 8 | 10 | 7 | 540 |
| 9–11 | 5 | 5 | 822–966 |

Read as a conditional hazard:

| Revisions so far | Facts reaching this point | Revised again | **% revised again** |
|---|---|---|---|
| 1 | 441,020 | 34,294 | **7.78** |
| 2 | 34,294 | 6,111 | **17.82** |
| 3 | 6,111 | 1,402 | **22.94** |
| 4 | 1,402 | 298 | 21.26 |
| 5 | 298 | 119 | 39.93 |

A fact that has been revised once has a **7.78%** chance of being
revised again. A fact that has been revised twice has **17.82%** 2.3× higher. A
fact revised three times has 22.94%.

Yes, and strongly. The hazard more than doubles after the second revision and
keeps rising. This is the most actionable result in §2: a figure with two
revisions already against it is not merely a figure that has settled after
some turbulence, it is a figure roughly three times more likely than a
once-revised one to move again. For a consumer, the number of prior revisions
on a fact is a usable risk signal, and it is available in `int_restatements`
as `n_reports` and `n_distinct_values` without any additional modelling.

Chain span is nearly constant at one year for lengths 1 through 6, which is the
§2 headline mechanism again: each additional link is one more annual comparative.

The chain model counts 441,020 chains against 426,706 restatements. The two
populations are defined differently and the gap is expected: chains count
step-to-step departures, so a fact revised away and then restored to its
original value is a chain of length 2 but not a restatement at all, since
`int_restatements` tests first against latest. There are 16,829 such
revised-and-restored facts, which more than accounts for the 14,314
difference; the offset in the other direction is multi-step chains whose
individual steps fall below the rounding threshold while the cumulative move
does not.

One company dominates: **Grupo Financiero Galicia** holds 2,721 chains of
which 979 are length 3 or more, 36% long chains, against a population-wide
1.39%. §2.7 establishes why, and it is not a control failure.

*Root cause: hypothesised.* Rising hazard is consistent with a subset of facts
being genuinely difficult to measure (estimates that keep being refined) rather
than with revision itself causing revision. This data cannot separate a persistent
per-fact propensity from a causal chain.

---

### 2.6 Serial restaters

Which companies restate repeatedly, and is it a sustained run of bad periods
or an occasional scatter?

`rst_serial_restaters` ranks filers by `NTILE(10)` on the
share of their reporting periods that carry a restatement, then separates runs
from scatters with a **gap-and-island** construction: subtracting a dense sequence
over the restated periods from the sequence over all reported periods leaves a
constant for each unbroken run. The timeline is the company's *own* reported
periods, not a calendar, because a company that skipped a year has no clean quarter
there to interrupt a run. Filers with fewer than four reporting periods are
excluded from the decile ranking before the window rather than masked after it,
a company with one reported period and one restated period sits at 100% and would
otherwise consume a slot in every decile. The four-period floor is a judgement
call, not a bound derived from the data; 1,714 of 8,692 companies fall below it,
carrying 26,411 restatements between them.

| Pattern | Companies | Mean % of periods restated | Mean restatements | Mean longest run |
|---|---|---|---|---|
| Sustained run (3+ consecutive) | 4,685 | 61.83 | 80.2 | 5.95 |
| Intermittent | 1,340 | 42.32 | 27.5 | 1.76 |
| None | 1,328 | 0.00 | 0.4 | 0.00 |
| Isolated (single period) | 927 | 26.75 | 7.3 | 1.00 |
| Scattered (3+ separate runs) | 412 | 34.71 | 16.9 | 1.60 |

| Decile | Companies | Mean % periods restated | Restatements | % of all restatements |
|---|---|---|---|---|
| 1 | 698 | 4.30 | 1,216 | 0.30 |
| 2 | 698 | 20.86 | 4,036 | 1.01 |
| 3 | 698 | 31.26 | 13,024 | 3.25 |
| 4 | 698 | 41.16 | 21,161 | 5.29 |
| 5 | 698 | 49.55 | 15,096 | 3.77 |
| 6 | 698 | 55.10 | 39,872 | 9.96 |
| 7 | 698 | 62.35 | 42,920 | 10.72 |
| 8 | 698 | 66.71 | 75,215 | 18.79 |
| 9 | 697 | 74.39 | 56,994 | 14.24 |
| 10 | 697 | 83.46 | 130,761 | **32.67** |

The top decile, 697 companies, accounts for **32.67%** of all
restatements. The top two deciles account for 46.9%. And **4,685 companies, 54% of
all filers, show a sustained run of three or more consecutive restated periods.**

Restating is normal, and that is the finding. §1.11 found defects concentrated
in a minority of filers: 69% failed no data quality rule at all. Restatements
behave nothing like that. 86.8% of companies restate something, 54% do it in
sustained runs, and the top decile holds only a third of the volume. This is
concentrated, but nowhere near the winner-take-all shape of the §1 defects.

This inverts §1's central result, and the inversion is the most important
cross-section in the report. Restatement volume is a *large*-filer phenomenon:

| Filer status | Companies | % restated of revisable | Mean restatements per company | % of companies restating |
|---|---|---|---|---|
| Non-accelerated | 4,607 | **5.433** | 45.1 | 88.41 |
| Accelerated | 1,031 | 4.885 | 56.5 | 94.76 |
| Large accelerated | 2,460 | **4.083** | 63.1 | **95.98** |

The *rate* per revisable fact still favours large filers, but by 1.33× rather than
the 8× gradient §1 found on data quality. Meanwhile **96% of large accelerated
filers restate something, against 88% of non-accelerated ones**, and large filers
restate 40% more facts each. A screen built on §1's conclusion, that small filers
are the risky ones, would miss almost every restatement at a large filer, and
there are more of them per company.

The top of the volume ranking is accordingly full of household names, not shells:

| Company | SIC | Periods | Restated | % | Restatements | Tags | Longest run |
|---|---|---|---|---|---|---|---|
| GRUPO FINANCIERO GALICIA SA | 6029 | 5 | 4 | 80.0 | 2,721 | 156 | 4 |
| COMPASS DIVERSIFIED HOLDINGS | 2510 | 11 | 10 | 90.9 | 1,248 | 102 | 10 |
| DOMINION ENERGY, INC | 4911 | 12 | 10 | 83.3 | 1,224 | 110 | 10 |
| AMERICAN INTERNATIONAL GROUP, INC. | 6331 | 12 | 9 | 75.0 | 894 | 123 | 9 |
| STARZ ENTERTAINMENT CORP /CN/ | 7812 | 12 | 9 | 75.0 | 843 | 85 | 9 |
| GENERAL ELECTRIC CO | 3600 | 12 | 8 | 66.7 | 836 | 102 | 8 |
| AMBAC FINANCIAL GROUP INC | 6351 | 12 | 9 | 75.0 | 817 | 113 | 9 |

These are not accusations of misreporting. A large filer reports far more
facts, so it has far more opportunities to revise one, and a company that
re-presents a full set of comparatives each year generates a long run
mechanically. The `none` category showing a mean of 0.4 restatements is the same
effect from the other side: those restatements attach to periods outside the
company's own reporting timeline (a 2023 filing revising a 2019 comparative) and
are counted in the totals but excluded from the run logic by design.

*Root cause: not established.* Whether large-filer restatement volume reflects
reporting complexity, more comparative re-presentation, or genuinely more
correction is not separable in this data.

---

### 2.7 Verification

§1.9 checked a rule and found it over-flagged by 60×. The same check runs here.
It finds less than that, but not nothing.

Twenty restatements were drawn from the 426,706 in reproducible order (`order by
md5(restatement_sk) limit 20`). Each one's full report sequence was pulled from
`fct_financial_fact` and read against `dim_filing` for form type and fiscal
period. The question was not whether the row was correct. It was whether the
filer actually published a different number for the same described fact, and
whether calling that a restatement means what a reader would assume.

| Verdict | Count |
|---|---|
| Genuine revision of the reported figure | 14 |
| Genuine change, but re-presentation rather than correction | 3 |
| Artefact, the underlying figure did not change | 3 |

Seventeen of twenty held up as real changes in what the filer published.
Fourteen held up as corrections in the sense the word normally carries.

Several are textbook. Nutex Health restated FY2024 stockholders' equity from
$146,344,749 to $132,437,993 in a 10-K/A, down 9.5%. Cellectar Biosciences
restated FY2023 non-operating income from +$917,147 to −$3,869,967, a sign
reversal. Faraday Future restated Q1-2023 related-party notes from $8,643,000 to
$9,201,000. Elvictor Group revised Q2-2024 net income from $32,701 to $32,071, a
digit transposition, corrected in the next 10-Q.

The three artefacts each turned out to represent a measurable class.

**Exact scale changes.** BC Partners Lending reported an investment at fair value
of 4,064 in its Q1-2023 10-Q and 4,064,000 in every filing after. Same digits, a
factor of exactly 1,000. The filer changed reporting scale. The holding did not
change value.

Across the population, 11,846 restatements (2.78%) have an exact power-of-ten
ratio between first and latest value. This is also what puts the p99 of the "all"
direction at exactly 999.0: a ×1000 scale change expressed as a percentage.

| Scale factor | Restatements |
|---|---|
| ×1000 | 4,774 |
| ÷1000 | 3,587 |
| ÷10 | 1,349 |
| ÷100 | 1,260 |
| ×10 | 697 |
| ×100 | 179 |
| **Total** | **11,846 (2.78%)** |

**Precision re-reporting.** HPS Corporate Capital Solutions reported Q1 2024
trustee fees of $55,943, then $56,000 a year later. That is a 0.102% "revision",
clearing the 0.1% threshold by two thousandths of a percent.

Barnes & Noble Education is the same defect inverted: treasury shares of 27,000
in two 10-Qs, then 27,267 in the 10-K. That filer's other treasury-share reports
settle which is which. Every one is a round thousand: 3,842,000; 1,948,000;
2,188,000; 2,426,000; 2,533,000. So 27,000 is the rounded report and 27,267 is
the exact one, and the underlying count never moved.

Of the 49,088 restatements below 1%, 4,420 have a later value that is an exact
multiple of 1,000 where the first value is not, against only 334 the other way
round. A 13× asymmetry is hard to explain as anything but precision changes being
read as revisions.

**Retroactive share splits.** Brain Scientific's diluted share count went from
29,520,454 to 347,333, a ratio of exactly 85.0. Luminar Technologies reported
291,942,087 common shares outstanding in eight consecutive filings, then
19,444,545 in the ninth: a ratio of 15.014, a 1-for-15 reverse split applied
retroactively.

FangDD Network is decisive, because it happened to all three share classes at
once:

| Class | 2024-04-19 | 2025-04-23 | 2025-09-29 |
|---|---|---|---|
| A | 33,312,108,296 | 5,922,152 | 370,135 |
| B | 490,418,360 | 87,186 | 5,450 |
| C | 7,071,427 | 1,258 | 79 |

The ratios are identical across all three: 5,625, then 16. No error correction
produces that. These are two successive share consolidations.

Across the population, 47.05% of share-denominated restatements carry a
near-integer shrink ratio between 1.5 and 10,000, against 2.45% of
USD-denominated ones. That is a 19× enrichment. Share counts are 11.87% of all
restatements with a median revision of 96%, and that median is a split artefact
rather than a measure of error.

#### A fourth class, found by following the magnitude tail

Restatements denominated in Argentine pesos number 9,725, 2.28% of the total,
with a median revision of 211% and 80 to 91% upward. Five issuers carry almost
all of them:

| Company | Restatements | Median revision | % upward |
|---|---|---|---|
| GRUPO FINANCIERO GALICIA SA | 2,707 | 136.4% | 86.6 |
| GRUPO SUPERVIELLE S.A. | 1,248 | 211.4% | 79.6 |
| MACRO BANK INC. | 1,072 | 211.4% | 90.9 |
| GAS TRANSPORTER OF THE SOUTH INC | 714 | 211.4% | 81.9 |
| TELECOM ARGENTINA SA | 687 | 211.4% | 71.9 |

Four of the five share a median of exactly 211.4%. That is the signature of a
common index, not of independent errors. It is IAS 29 hyperinflation accounting:
Argentine issuers must restate prior-period figures into current purchasing power
every reporting period. Mandatory re-presentation, the opposite of a control
failure, and it explains why Grupo Financiero Galicia tops the §2.5 chain
concentration with 979 long chains.

#### Four checks across the whole population

Everything above was found by sampling and then measured. These four were defined
first and counted directly, so they carry no sampling error. Each is a closed
predicate over `int_restatements`, and the first three are mutually disjoint.

| Category | Predicate | Restatements | % of 426,706 |
|---|---|---|---|
| Zero-origin | `first_reported_value = 0` | 6,950 | 1.63 |
| Extreme magnitude | `abs(pct_revision) > 100` | 10,061 | 2.36 |
| Sign flip | `first_reported_value = -latest_reported_value` | 29,118 | 6.82 |
| **Union (disjoint)** | | **46,129** | **10.81** |

Roughly one restatement in nine is identifiable from the values alone as a
reclassification, a rescaling or a sign correction rather than a revision of a
value. The fourth check is not a class of rows but a test of §2.2's direction
result against the other three.

**Zero-origin (6,950).** A fact first published as zero and later at a non-zero
value. There is no denominator, so these carry no `pct_revision` and sit outside
every magnitude statistic. The dominant mechanism is reclassification into a line
that previously did not exist. Discontinued operations is the clearest case: 860
of the 6,950 carry a tag naming them.

General Electric is the worked example, because the arithmetic closes. Financing
cash flow from discontinued operations, FY2022:

| Filed | Form | Discontinued ops | Continuing ops | Total financing |
|---|---|---|---|---|
| 2023-02-10 | 10-K | 0 | −5,585,000,000 | −5,585,000,000 |
| 2023-04-25 | 8-K | 8,102,000,000 | −13,688,000,000 | −5,585,000,000 |
| 2024-02-02 | 10-K | 8,102,000,000 | −13,688,000,000 | −5,585,000,000 |
| 2025-02-03 | 10-K | 7,955,000,000 | −13,540,000,000 | −5,585,000,000 |

The total never moves. GE spun off GE HealthCare in January 2023 and recast
FY2022 into discontinued-operations presentation in the 8-K that April. The
discontinued line moves from 0 to +8,102,000,000 and the continuing line moves by
−8,103,000,000, offsetting to within one million dollars of GE's own rounding.
Not one figure about 2022 changed. What changed was the partition of an unchanged
total between two tags.

Note that this single event produces two rows in `int_restatements`, one on each
tag. A reclassification inflates the count by as many tags as it touches.

The class is not uniformly artefactual and the honest reading is narrower than
"all reclassification". Merck's FY2023 acquired-IPR&D write-off is reported as 0
in the FY2023 10-K and $11,409,000,000 in the FY2024 10-K. Nothing here shows
whether that is a repartition like GE's or a figure the first filing simply did
not break out, and no offsetting counterpart was sought for it. What the class
does share is that none of these is a filer changing its mind about a number's
magnitude, which is what "restatement" implies to a reader.

6,233 of the 6,950 are USD and 446 are share counts. The median arrives at 364
days, matching the population.

**Extreme magnitude (10,061).** Revisions exceeding 10,000% of the original. A
figure genuinely wrong by two orders of magnitude and surviving audit is rare. A
figure whose scale, unit or share basis changed is not. Three mechanisms account
for most of the bucket, and 5,358 of the 10,061 (53%) have an exact power-of-ten
ratio between first and latest value, which is the strongest available signature
that no economic quantity moved.

Kamada Ltd is the cleanest rescaling. Between its 6-K of 2023-11-13 and its 6-K
of 2024-11-13, 145 of 151 restatements are a factor of exactly 1,000, across 82
distinct tags: assets 337,056 → 337,056,000, additional paid-in capital 265,700 →
265,700,000. One filer changed its reporting scale from thousands to units and
contributed 145 rows, none of them a changed fact.

Aditxt is the per-share mechanism, and it proves itself because the denominator
is in the dataset too:

| Filed | Form | Diluted EPS | Weighted average diluted shares |
|---|---|---|---|
| 2024-05-20 | 10-Q | −9.21 | 1,610,872 |
| 2025-05-15 | 10-Q | −91,439.43 | 161 |

The share count shrinks by 10,005× and the loss per share grows by 9,928×, the
same ratio to within 0.8%, which is the rounding of a two-decimal EPS. A reverse
split applied retroactively to Q1-2024 comparatives, registering as a 992,700%
"restatement" of EPS.

This extends the split finding above. That one measured splits only on
share-count units, but the same event re-presents every per-share figure as well.
1,176 of the extreme bucket are per-share tags against 2,938 share counts.

The third mechanism is reclassification off a near-zero base. AIG reported FY2022
income from discontinued operations as −$1,000,000 in the 10-Ks of 2023 and 2024,
then $8,383,000,000 in the 10-K of 2025-02-13, on deconsolidating Corebridge. The
value moved by 838,400% because the base was a rounding artefact, not because the
figure was wrong by that much. Percentage revision is not a meaningful statistic
when the denominator is one rounding unit. 2,396 of the extreme bucket are
decreases against 7,665 increases, which is the asymmetry a near-zero base
produces.

**Sign flips (29,118).** `first_reported_value = -latest_reported_value` exactly.
The magnitude is bit-identical and only the sign changed. This is the most
mechanical category in the report. It is not an approximation or a threshold but
an equality, and at 6.82% it is the largest of the three.

| Company | Tag | Period | First | Latest |
|---|---|---|---|---|
| Crown Castle Inc. | `InterestExpenseDebt` | FY2023 | 850,000,000 | −850,000,000 |
| Edgewell Personal Care | `NetCashProvidedByUsedInOperatingActivities` | FY2024 | 231,000,000 | −231,000,000 |
| Johnson & Johnson | `OtherComprehensiveIncomeLossForeignCurrencyTranslationAdjustmentTax` | Q3-2024 | −51,000,000 | 51,000,000 |
| Boston Properties | `RepaymentsOfOtherDebt` | Q2-2023 | −730,000,000 | 730,000,000 |

Crown Castle reported $850m of interest expense in its FY2023 10-K and −$850m for
the same period in its FY2024 10-K. Interest expense did not become interest
income. The element's sign convention changed: whether an expense is tagged
positive as a cost or negative as a deduction. XBRL permits both, and
`negatedLabel` presentation reverses the displayed sign, so the rendered statement
can look identical either way while the tagged value flips.

The tag distribution confirms it. The concentration sits in exactly the concepts
whose sign convention is contested: `IncomeTaxExpenseBenefit` (763, expense or
benefit), `IncreaseDecreaseInAccountsReceivable` (308) and
`IncreaseDecreaseInInventories` (284, working-capital movements presented as the
change or as its cash effect), `StockRepurchasedAndRetiredDuringPeriodValue`
(279). And 29,045 of the 29,118 have exactly two distinct values, a single flip
with no further movement, which is what a one-time convention change looks like
and not what an error under correction looks like.

Not every flip is a convention change, and the sample says so. Edgewell's
operating cash flow is in the table above, and the sign of operating cash flow is
not a contested convention, so that row is either a tagging error or a genuine
sign correction. The values cannot say which. The claim the category supports is
narrower than "all 29,118 are conventions". It is that in none of them did the
reported magnitude change, so none is a revision of a value, whatever else it is.

The fourth check tests the direction result against the other three classes.
§2.2 reports 57.76% of revisions as reductions. A sign flip has an identical magnitude, so calling it an increase
or a decrease is meaningless. `revision_direction` reads the sign of
`absolute_revision`, which for a flip is entirely an artefact of the convention
that changed. If the downward skew were manufactured by these categories,
removing them would collapse it.

| Population | Restatements | % downward |
|---|---|---|
| All | 426,706 | 57.76 |
| Excluding sign flips | 397,588 | **58.51** |
| Excluding all three categories | 380,577 | **60.02** |
| Sign flips alone | 29,118 | 47.54 |
| Zero-origin alone | 6,950 | 25.94 |
| Extreme magnitude alone | 10,061 | 23.81 |

It does not collapse. It strengthens. Sign flips are near-balanced at 47.54%
downward, which is what a convention change should look like, since it has no
reason to prefer a direction. Zero-origin and extreme-magnitude restatements are
strongly upward, 74% and 76%, because both are dominated by values rising off a
zero or near-zero base. Removing all three raises the downward share from 57.76%
to 60.02%. The direction finding does not depend on the contaminated rows. It was
diluted by them.

*Root cause: established for sign flips and rescalings, hypothesised for
zero-origin.* Bit-identical magnitudes and exact power-of-ten ratios are
signatures no error process produces, and the Aditxt and GE cases are confirmed
by an independent series in the same dataset. The zero-origin attribution to
reclassification rests on the GE arithmetic and the discontinued-operations tag
concentration. Strong, but one worked case rather than a population test.

#### Aggregate effect on the headline

Seven classes are now quantified from two methods: three found by sampling and
then measured, three defined first and counted directly, plus the split class.
They overlap, so they cannot be added.

| Class | Found by | Restatements | Overlap with the direct counts |
|---|---|---|---|
| Sign flips | direct count | 29,118 | (disjoint) |
| Extreme magnitude | direct count | 10,061 | (disjoint) |
| Zero-origin | direct count | 6,950 | (disjoint) |
| Power-of-ten scale changes | sampling | 11,846 | 4,778 inside the extreme bucket |
| IAS 29 re-presentation (ARS) | sampling | 9,725 | 40 |
| Sub-1% precision re-reports | sampling | ~4,420 | none |
| **Union** | | **~69,500** | **16.3% of the population** |

The union's last figure is approximate. Reproducing the scale-change predicate
at the tolerance used for the direct counts returns 14,044 rather than the
11,846 tabulated above, so the union sits between roughly 67,000 and 69,500.
Call it 16% of the population, give or take half a point.

Retroactive share splits (23,839) are disjoint from all three directly counted
categories. A split on a share count is a shrink of less than 100%, so it can
never enter the extreme bucket, and they stay out of the union because they are
genuine changes to a published figure rather than artefacts. Their per-share
counterparts are different: the Aditxt case shows the same split event
re-presenting EPS as a five-figure percentage, and those 1,176 per-share rows are
inside the extreme bucket.

Removing the artefact union moves the headline rate from 4.785% to approximately
4.01%. That is the ceiling on the false-positive correction, and it is materially
larger than the three sampling-found classes reach on their own: 11,846 scale
changes, 9,725 IAS 29 re-presentations and ~4,420 precision re-reports total
25,991 rows, or 6.09% of the population. The direct counts found more than the
sample did, which is the expected direction and the reason they were run.

The headline finding survives. A 16% correction leaves a restatement rate near
4%, still low single digits, still the shape the design predicted. Nothing like
§1.9's 60×.

Two results survive in different ways. The direction result strengthens: the
artefact classes were diluting the downward skew rather than creating it, and
removing all three raises reductions from 57.76% to 60.02%. The magnitude
distribution in §2.2 does not survive unqualified. The mass above 90% is
substantially re-presentation rather than correction, and §2.2 is written
accordingly.

What verification did not cover. Nothing was checked against the original
filings on EDGAR. All inspection was against the loaded data, so a sequence that
is internally coherent may still misrepresent what the filer submitted. Twenty is
a small sample against 426,706 and supports classification of failure modes
rather than a precise false-positive rate; the population-level tests are what
carry the percentages. No attempt was made to distinguish a correction from a
reclassification where the values give no signature, which §2.8 records as a
structural limit rather than a sampling one.

---

### 2.8 Limitations

The rounding threshold is a judgement call. 0.001 was chosen to match §1.10's
balance sheet bound, not derived from the revision distribution. Unlike §1.10,
where the gap distribution was bimodal and 0.1% sat in the natural break, the
revision distribution has no such break, it decays smoothly through the small
bands, so any bound in this region is an assertion. The rate's sensitivity to it:

| Threshold | Restatements | % of revisable |
|---|---|---|
| none (any difference) | 489,775 | 5.492 |
| 0.01% | 456,418 | 5.118 |
| 0.05% | 436,924 | 4.899 |
| **0.1% (shipped)** | **426,706** | **4.785** |
| 0.2% | 414,942 | 4.653 |
| 0.5% | 395,656 | 4.436 |
| 1% | 377,618 | 4.234 |
| 5% | 320,574 | 3.594 |

Moving the threshold across two orders of magnitude, from 0.01% to 5%, moves the
rate from 5.12% to 3.59%, a factor of 1.4. **The headline is robust to the
threshold**; removing it entirely adds 63,069 restatements (14.8%) and the rate is
still 5.49%. What the threshold does not do is separate the classes §2.7 found:
scale changes and split re-presentations sit far above any plausible bound and no
choice of threshold removes them.

Restatement detection cannot distinguish a correction from a reclassification
or a taxonomy change. This is the structural limit of the method and it is not
fixable by tuning. `int_restatements` observes that a filer published a different
number for the same described fact; it cannot observe *why*. Four distinct events
are indistinguishable in the values alone:

- a genuine error correction
- a reclassification between line items, where a figure moves from one tag to
  another and both change without anything economic having happened
- a retroactive re-presentation: reverse splits (§2.7), IAS 29 hyperinflation
  restatement (§2.7), discontinued operations reclassified out of continuing
  operations, or a change in accounting policy applied to prior periods
- a change in reported scale or precision (§2.7)

§2.7 quantifies the classes that leave a numeric signature, and the direct counts
there put the identifiable artefacts at roughly 16% of the population. Two of those
categories are reclassification signatures, zero origin facts and reclassification
off a near-zero base, so reclassification is no longer entirely unquantified. But
the general case still is: where a figure moves between two tags that both already
carry non-zero values, the move leaves no signature in the values at all, it is not
counted anywhere in this report, and there is no reason to think it is small. **A restatement in
this dataset should be read as "the published value for this fact changed", not as
"the filer got it wrong".** Every use of the word in §2 carries that meaning.

Twelve quarters is a short window and it biases the rate downward. The loaded
range is 2023 Q1 to 2025 Q4. A revision arriving after 2025-12-31 is invisible, and
since the median revision arrives 364 days after first publication, that censoring
is severe at the end of the window. The effect is directly measurable:

| Year of first report | Revisable facts | Restated | % restated |
|---|---|---|---|
| 2023 | 4,435,760 | 237,433 | **5.353** |
| 2024 | 3,407,857 | 164,027 | 4.813 |
| 2025 | 1,074,855 | 25,246 | **2.349** |

Facts first published in 2023 had up to three years of observation and restate at
5.35%. Facts first published in 2025 had at most one and restate at 2.35%, less
than half. The same effect appears in the denominator: 52% of facts first reported
in 2024 were ever reported again, against only 15% of those first reported in 2025.

The 4.785% headline is therefore a lower bound. The best-observed cohort
restates at 5.35%, and even that is censored, since a 2023 figure can still be
revised in 2026. Loading the SEC's full history from 2009 Q2 would raise the rate;
this analysis cannot say by how much.

Left-censoring bites at the other end and is why §2.4 discards its first four
quarters: a revision published in 2023 Q1 has no original in the window to be a
revision *of*.

Further limits:

- **The 154 conflicting-duplicate groups from §1.6 are handled, not solved.** Where
  one filing carries two values under one composite key, `int_restatements`
  collapses to one report per publication date and tiebreaks on highest accession
  then highest value. The tiebreak is arbitrary, no ordering is more correct than
  another, but it is *total*, which is what makes the model idempotent. An earlier
  formulation tiebroke on accession alone; because the conflicting rows share an
  accession, the choice fell to scan order and two consecutive builds returned
  426,713 then 426,716 rows with different checksums. The current model is stable
  at 426,706, verified this session.
- **`dim_company` carries roughly 7% spurious version transitions.** 128 of 1,864
  transitions revert to a fiscal-year-end value the CIK already held, the signature
  of filers reporting a quarter end in the `fye` field on 10-Qs rather than a real
  fiscal year change. Sector attribution in §2.1 range joins through those
  versions. The effect is small, the spurious versions carry the same SIC as the
  ones either side, so a division assignment is unaffected, but the SCD2 is not
  clean and §2.1's as-at attribution inherits that.
- **`segments` is a flattened string and is matched as one.** A fact whose
  distinguishing dimension never reaches that string (§1.6: individual contract or
  holding identifiers) can be compared against a different fact. This is the same
  defect that produces the 154 duplicates, and it is a source of false restatements
  that cannot be bounded from this data.
- **No form type filtering.** Registration statements, prospectuses and 8-Ks are
  treated as reports of a fact like any other, which is deliberate, an S-1 that
  publishes a different figure has published a different figure, but it means
  §2's population is not restricted to periodic reports.
- **Zero denominator restatements (6,950) have no percentage** and are excluded
  from every magnitude statistic while remaining in every count. §2.7 examines them
  as a class and finds them dominated by reclassification rather than revision, so
  their presence in the headline count is itself a known overstatement.
- **Root causes in §2 are inferred from aggregate data and sampled sequences, never
  confirmed against source filings on EDGAR.** The IAS 29 and reverse-split
  attributions in §2.7 are the best-supported, resting on identical ratios across
  independent series; they are still inferences.

---

## §3 Filing behaviour and comparables (Stage 3)

**Report date:** 2026-08-31
**Models:** `fil_lag_by_form`, `fil_lag_trend`, `fil_deadline_filers`,
`pit_peer_comparables`
**Companion document:** [`docs/performance.md`](performance.md) measures three
query optimisations against `fct_financial_fact` on the same data.

### Scope

§1 tested each filing against itself. §2 tested filings against each other. §3
asks what the two dates are worth once they are kept apart: when figures become
public, whether that has moved, which filers work to the deadline, and what it
costs to compare companies using numbers that did not exist on the date the
comparison claims to stand on.

The first three sections are about the filing calendar and use `dim_filing`
only. The fourth uses the whole warehouse, the Type 2 company dimension, the
fact table, and the two dates, and is the section the project exists to
support. §3.4 constructs the same peer comparison twice over the identical
companies and the identical fiscal year, once from what was knowable on
2024-06-30 and once from everything filed since, and counts what moved.

Population throughout is the 69,907 original 10-K and 10-Q filings with a
non-null filer status and a filing lag between 0 and 1,095 days, the same
plausibility bound §1.2 applied. Amendments are counted separately where they
are counted at all.

---

### 3.1 Filing lag by form and filer status

§1.2 established the wait from period end to publication and that result is
carried through `fil_lag_by_form` unchanged rather than recomputed: 54 days for
a large accelerated filer's 10-K, 67 for an accelerated, 87 for a
non-accelerated, and 34 / 38 / 44 for the corresponding 10-Qs. The gradient with
filer size is §1.2's finding and stands.

What is new is the second wait. §1.2 could only measure each filing against
its own period. It observed that a 10-K/A arrives at a median of 207 days
against 67 for a 10-K and inferred a gap of "roughly 140 days" by subtracting
one median from the other. `fil_lag_by_form` pairs each amendment to the
specific original it amends, same company, same base form, same period, the
last one filed on or before it, and measures the gap directly.

The direct measurement is 98 days, not 140. Over the 1,438 amendments that
have an original inside the loaded range:

| | Days from original to amendment |
|---|---|
| p25 | 24 |
| **Median** | **98** |
| p75 | 197 |
| p90 | 296 |

10-K and 10-Q amendments give a median of 98 days each, independently. The
difference-of-medians estimate overstated the gap by 43%, and the reason is
visible in the model: the two medians §1.2 subtracted are not drawn from the
same filings. The 10-K/A lag distribution includes amendments of originals filed
before 2023-01-03, which are outside the loaded range and inflate the amendment
lag without contributing a matching original. Pairing removes them from both
sides at once.

98 is itself a lower bound, and the direction is knowable. The 411
amendments (22.2%) with no original in range are excluded, and they are excluded
precisely *because* their original was filed before 2023-01-03, that is, they
are the amendments with the longest gaps. Left-censoring therefore trims the
right tail of this distribution, not a random slice of it. The true median gap
over all amendments is above 98 and below the 140 the subtraction gave, and this
range cannot narrow it further.

By form and filer status, over the amendments matched to an original:

| Form | Filer status | Amendments | Matched | Median gap | p90 | Max |
|---|---|---|---|---|---|---|
| 10-K/A | Large accelerated | 98 | 89 | **159** | 305 | 380 |
| 10-K/A | Accelerated | 52 | 45 | 95 | 345 | 569 |
| 10-K/A | Non-accelerated | 722 | 598 | 92 | 276 | 694 |
| 10-Q/A | Large accelerated | 97 | 77 | 111 | 250 | 566 |
| 10-Q/A | Accelerated | 76 | 59 | **158** | 305 | 534 |
| 10-Q/A | Non-accelerated | 804 | 570 | 94 | 301 | 757 |

77.8% of amendments match to an original in range; the rest amend a filing from
before 2023 and are counted in `n_amendments` but not in `n_matched_to_original`,
which is why both columns are reported.

The direction here is the opposite of the lag gradient. Small filers publish
late and amend fast; large accelerated filers publish fast and take the longest
to amend, a median 159 days against 92 for non-accelerated filers on the same
form. The lag gradient and the amendment gradient do not agree, so filer size
is not a single axis of promptness. *Root cause: not established.* A larger
filer's amendment plausibly requires more audit work, but nothing here tests
that.

How often a form gets amended at all, attributed to the original rather than
the amendment:

| Form | Filer status | Originals | Observed amended | % |
|---|---|---|---|---|
| 10-K | Large accelerated | 6,302 | 87 | 1.38 |
| 10-K | Accelerated | 2,275 | 44 | 1.93 |
| 10-K | Non-accelerated | 8,927 | 513 | **5.75** |
| 10-Q | Large accelerated | 18,680 | 76 | 0.41 |
| 10-Q | Accelerated | 6,675 | 59 | 0.88 |
| 10-Q | Non-accelerated | 27,048 | 530 | **1.96** |

A non-accelerated filer's 10-K is amended at four times the rate of a large
accelerated filer's. This agrees with §1's data quality gradient and disagrees
with §2's restatement gradient, where 96% of large accelerated filers restate
against 88% of non-accelerated ones. The two are measuring different things and
the disagreement is the point: amendment rate tracks data quality, restatement
rate does not, because most restatements never appear in an amendment (§2, "One
result organises the rest").

The filer's own amendment flag undercounts by half. The SEC's `prevrpt` flag
marks an original whose filer indicated it was superseded. Across the 69,907
originals, 842 (1.20%) carry the flag but 1,309 (1.87%) have an amendment
actually present in the loaded range. Both counts ship, because the disagreement
is informative rather than a defect to be resolved: an original flagged as
amended whose amendment lands after 2025-12-31 appears in the first count and
not the second, and an amendment filed without the original being flagged
appears in the second and not the first. Neither is a reliable amendment
indicator on its own.

---

### 3.2 Has the wait moved across the twelve quarters?

No, and the sample cannot support a finer answer than that.

`fil_lag_trend` fits a straight line to each form-and-status series over the
twelve filing quarters, and reports the r-squared of the same fit and the
residual spread beside the slope. All six series:

| Form | Filer status | Slope (days/qtr) | Days/year | r² | Series SD | Reading |
|---|---|---|---|---|---|---|
| 10-K | Large accelerated | −0.217 | −0.87 | 0.144 | 2.06 | no trend |
| 10-K | Accelerated | −0.245 | −0.98 | 0.106 | 2.72 | no trend |
| 10-K | Non-accelerated | 0.000 | 0.00 | 0.000 | 8.68 | no trend |
| 10-Q | Large accelerated | +0.129 | +0.52 | 0.160 | 1.16 | no trend |
| 10-Q | Accelerated | −0.056 | −0.22 | 0.269 | 0.39 | no trend |
| 10-Q | Non-accelerated | +0.037 | +0.15 | 0.031 | 0.75 | no trend |

A straight line through twelve seasonal points is treated as describing the
series only where it accounts for at least half the variation (r² ≥ 0.5). No
series reaches it. The highest is 0.269, and that one, 10-Q accelerated, has a
series standard deviation of 0.39 days, so the line is fitted to a series that
barely moves at all. The largest annual drift any series supports is under one
day per year, against a median lag of 34 to 87 days.

Seasonality is the reason, and it is an order of magnitude larger than any
trend. 10-K non-accelerated filers have a median lag of 80 days on filings
made in Q1 and 107 on filings made in Q2, a 27-day swing inside one year,
against a series standard deviation of 8.68 and a fitted slope of exactly zero.
The Q1 10-Ks are calendar-year filers near their deadline; the Q2 10-Ks are the
same population's late filers plus off-calendar filers. Comparing adjacent
quarters measures the calendar. Both comparisons in the model therefore span a
full seasonal cycle: a trailing four-quarter mean, and the same quarter one year
earlier.

Aggregation is by **filing** quarter, not period quarter. On a period axis the
recent end is censored, a period ending 2025-12-31 is filed in 2026 and is
almost entirely absent from the loaded range, so the last quarters would show a
spuriously short lag drawn from the early filers alone. On a filing axis,
2023Q1 through 2025Q4 are twelve complete quarters.

Twelve points per series is a short series, and the points are not equally
weighted. The 10-K series are dominated by one quarter each year: 1,809 large
accelerated 10-Ks were filed in 2023Q1 against 93 in 2023Q2. The accelerated
10-K series thins to 36 filings in 2023Q3 and 38 in 2025Q4, and the 10-Q large
accelerated series to 325 in 2024Q1. A median computed on 36 filings carries
several days of sampling error on its own, which is comparable to the entire
fitted movement across three years. Four quarters of each series additionally
have no trailing comparison at all, because a full cycle has not yet accrued;
those rows carry `has_full_trailing_window = false` and are flagged rather
than dropped, so the early quarters keep their own medians and only the
derived comparison is marked incomplete.

What this section establishes is a negative: **filing promptness in this data is
a stable seasonal pattern with no detectable drift over twelve quarters.** It
does not establish that no drift exists. A slope of one day per year would be
invisible here, and the series is too short and too seasonal to rule one out.

---

### 3.3 Filers who work to the deadline

A lag in days is not comparable across filers, because the deadline is not. A
large accelerated filer's 10-K is due in 60 days and a non-accelerated filer's
in 90, so the same 75-day lag is fifteen days late for one and fifteen days early
for the other. `fil_deadline_filers` measures every filing against its own
statutory due date instead, which puts all three statuses on one axis.

Deadlines are 17 CFR 240.13a-1 and 13a-13: 60 / 75 / 90 days for a 10-K by
descending filer size, and 40 / 40 / 45 for a 10-Q. Rule 0-3(a) rolls a due date
falling on a weekend to the next business day, which the model applies. Federal
holidays are not modelled; §3.5 measures what that costs.

The margin threshold is derived, not chosen. A filing is treated as made to
the deadline if it lands within one day of its due date. Across the observed
distribution of margins, filings land on the due date itself at **20.1%** of the
−3..+14 day window and on the following day at **10.8%**, against a flat plateau
of 6.9–8.2% per day from day 2 through day 7. The spike is the signature of
deadline-driven filing; the plateau is background. A five-day bound was tried
first and rejected: it captures **60.3%** of all filings, because the
filing-level median margin is 4 days and the wider bound admits the whole
plateau. Both figures were re-derived in §3.5's pass and match.

A late filing counts as a deadline filing. The company was working to the
deadline and missed it, so the flag is an upper bound on the margin rather than
a band around zero.

Across 7,264 companies and 69,907 filings, 25,782 filings (36.88%) were made at
the deadline.

The consecutive-run distinction is what the model exists to draw. A count
alone cannot separate a company that habitually files at the wire from one that
had two bad quarters and filed early the rest of the time. Runs of consecutive
deadline filings are found by gap and island over each company's own filing
sequence, so the two cases separate on structure rather than on volume:

| Pattern | Definition | Companies | Avg filings | Avg median margin | Avg % at deadline |
|---|---|---|---|---|---|
| **habitual** | longest run ≥ 3 consecutive | **2,862** | 10.0 | −7.6 | 74.3 |
| never at deadline | no filing within one day | 1,734 | 10.2 | +10.1 | 0.0 |
| intermittent | 2+ deadline filings, no run of 3 | 1,141 | 8.8 | −2.0 | 38.0 |
| isolated | exactly one | 1,094 | 8.0 | −2.5 | 30.4 |
| episodic | 3+ separate runs, none ≥ 3 long | 433 | 11.3 | +3.2 | 37.6 |

The distinction earns its place. 1,141 intermittent and 1,094 isolated companies
between them file at the deadline 30–38% of the time, a rate that a count-based
screen would not separate from the habitual group's 74% by much, and would
certainly not separate from the episodic group's 37.6%. The structural test
does: habitual companies reach a longest run of 3 and above (maximum 19,
covering catch-up filings), episodic ones repeat the behaviour in separate bursts
with early filings between, and intermittent ones never string three together at
all.

Habitual is not one behaviour. Of the 2,862 habitual companies, 1,439 have a
median margin of 0 or 1 day, genuinely disciplined to the wire, and 794 have a
negative median, meaning their typical filing is late. 900 are habitual and have
never filed late once. These are opposite phenomena sharing a label, and §3.5
shows the decile ranking has the same problem more acutely.

Deciles are assigned over companies with at least four filings (one year of
periodic reporting), a floor applied before the window rather than after it: a
company with a single filing that happened to land on its due date would
otherwise consume a slot in the tightest decile and push a habitual filer out of
it. 6,418 of 7,264 companies are rankable.

| Decile | Median margin range | Avg % at deadline | Avg longest run | Habitual |
|---|---|---|---|---|
| 1 | −714 to −2 | 93.8 | 7.5 | 627 of 642 |
| 2 | −1.5 to 0 | 91.2 | 7.8 | 634 |
| 3 | 0 to 1 | 71.6 | 4.7 | 600 |
| 4 | 1 to 2 | 52.4 | 3.5 | 468 |
| 5 | 2 to 3.5 | 31.1 | 2.2 | 226 |
| … | | | | |
| 10 | 11 to 30 | 2.2 | 0.2 | 4 |

---

### 3.4 Point-in-time peer comparables

This is what the warehouse is for.

Every other section in this report describes the data. This one measures what it
costs to ignore the mechanic the project is built on. `pit_peer_comparables`
constructs the same peer comparison twice, over the identical companies and the
identical fiscal year:

- **The point-in-time view** uses only what was knowable on 2024-06-30: facts
  with `filed_date` strictly before the cutoff, and each company's SIC code as
  recorded on the `dim_company` version current on that date.
- **The latest view** uses every filing in the loaded range and each company's
  present-day SIC.

Same metric, same peer universe, same period, same code. The two views differ in
one date and nothing else, the model is written once and evaluated twice
against an `as_of_dates` relation, so the point-in-time view cannot drift from
the latest view on anything except the visibility rule itself.

The target is annual periods ending in the second half of 2023, chosen so every
company in the population had filed by the cutoff and had eighteen months of
loaded range afterwards in which to revise. Metrics are net margin and
year-on-year revenue growth. Peers are SIC major groups with at least 20
companies. The fiscal period is fixed once from the point-in-time view and both
sides are pinned to it, so a restatement is never compared against a newer
annual period. The population is held to companies present in **both** views,
3,441 companies across 35 SIC groups, because a company absent from one side
would shift every peer's rank on the other and be counted as a change it did not
cause.

| | Companies | % of 3,441 |
|---|---|---|
| At least one input value changed between views | 323 | 9.39 |
| **Changed quartile on margin or growth** | **264** | **7.67** |
| **Changed quartile materially** | **103** | **2.99** |
| by metric: margin | 116 changed / 42 material | |
| by metric: growth | 167 changed / 75 material | |

Stated as an argument: a screen, a benchmark or a back-test that ranks
companies on their FY2023 numbers using data pulled today is not reproducing
what an analyst could have seen in mid-2024. It is ranking them on figures that
did not exist then, against peers classified into industries they had not yet
been moved to. Run over this population, that substitution silently reclassifies
**103 of 3,441 companies into a different performance quartile**, one company
in thirty-three, without any indication on the output that anything moved. The
comparison looks identical either way. Nothing in a table of quartiles marks
which rows are anachronisms.

One quartile is not the ceiling. **42 of the 103 moved two or more quartiles and
13 moved three**, top quartile to bottom, or the reverse:

| Margin shift | Changed | Material | | Growth shift | Changed | Material |
|---|---|---|---|---|---|---|
| −2 | 6 | 6 | | −3 | 7 | 7 |
| −1 | 55 | 15 | | −2 | 7 | 7 |
| +1 | 49 | 15 | | −1 | 71 | 18 |
| +2 | 4 | 4 | | +1 | 63 | 24 |
| +3 | 2 | 2 | | +2 | 15 | 15 |
| | | | | +3 | 4 | 4 |

Materiality is a derived bound, not a chosen one. A quartile change is called
material only where the company's rank within its peer group also moved by at
least 0.05. The bound comes from the observed separation between the two
mechanisms that move a bucket: where the company's own inputs were restated, the
median rank shift is 0.044 for margin and 0.235 for growth; where only the peer
distribution moved, the median is 0.010 and the largest shift anywhere in the
model is 0.056. A company sitting within a hundredth of a quartile cut changes
bucket when four peers join its SIC group without anything about it changing.
Counting those alongside a genuine reordering would overstate the headline by
roughly half, 264 against 103.

The model attributes every change, and that attribution is the most useful
column in it:

| Attribution | Companies | Material | Mean abs. margin shift |
|---|---|---|---|
| unchanged | 3,177 | 0 | 0.007 |
| peer distribution moved | 150 | 4 | 0.012 |
| **own values restated** | **88** | **74** | 0.109 |
| **SIC reclassified** | **19** | **18** | 0.182 |
| restated *and* reclassified | 7 | 7 | 0.272 |

Two findings sit in that table.

First, reclassification is nearly as destructive as restatement and is far
less expected. Only 19 companies changed SIC major group, but 18 of the 19
changed quartile materially, a 95% hit rate, against 84% for restatement. The
reason is mechanical: a restatement moves one company within a fixed
distribution, while a reclassification moves it into a different distribution
entirely. The cohort is identifiable. Nine companies moved from software,
prepackaged software or electronic components into finance (SIC 61/62), six of
them from major group 73 alone: Strategy Inc, MARA Holdings, Bit Mining, GRIID
Infrastructure, Strive, Amber International, Canaan, Ebang and TRON. These are
crypto-treasury companies that reclassified as financial firms after the period.
A peer screen of FY2023 software companies run today omits them; a screen run in
mid-2024 included them. Neither is wrong about its own date. They are answers to
different questions, and only one of them is the question a back-test is asking.

Second, 150 companies changed quartile without anything about them changing at
all. Their own values held, their SIC held, and their peers' restatements moved
the distribution underneath them. Only 4 of the 150 clear the materiality bound,
so this is a small effect on the headline, but it is the case most easily
mistaken for stability: a company can be a perfectly faithful record of itself
and still be ranked differently, because point-in-time correctness is a property
of the comparison, not of the row.

Worked examples of the largest material moves, all from `own_values_restated`:

| Company | Metric | Point-in-time | Latest | Quartile |
|---|---|---|---|---|
| Energy Focus | FY2023 net income | +$4.30M | −$4.29M | 1 → 4 |
| Horizon Kinetics | FY2023 revenue | $3.4M | $47.3M | 1 → 4 |
| Broadwind | FY2023 revenue | $48.9M | $203.5M | 1 → 3 |
| Ambac Financial | FY2023 revenue | $269.0M | $124.7M | growth 4 → 1 |
| Cango | FY2023 revenue | $239.7M | $1,701.9M | growth 4 → 1 |
| Alternus Clean Energy | FY2023 revenue | $20.1M | $3.5M | growth 1 → 4 |

Two of these six do not survive §3.5's verification, Energy Focus and
Broadwind, and that section says why.

---

### 3.5 Verification

§1.9's most defensible result came from checking a rule and finding it
over-flagged by 60×. §2.7 sampled twenty restatements and found three artefact
classes that were then counted across the population. The same skepticism is
applied here, and it finds two real problems: one in §3.3 that halves a headline,
and one in §3.4 that removes seven cases from another.

The point-in-time view reproduces exactly. The visibility rule was
recomputed independently of the model, a `distinct on` over `fct_financial_fact`
filtered to `filed_date < 2024-06-30`, written from the specification rather than
from the model code, and compared row by row against `pit_net_income` for all
3,441 companies. **3,441 agree, 0 disagree.** No fact filed on or after the
cutoff reaches the point-in-time view. This is the one thing in §3.4 that had to
be exactly right, since every number in the section is a difference between the
two views, and it is.

Deadline calculations: spot-checked against known filings, and they hold.
Six filings were checked by hand against the statutory rule and the calendar:

| Company | Form | Period end | Filed | Lag | Deadline | Margin |
|---|---|---|---|---|---|---|
| Apple | 10-K | 2023-09-30 | 2023-11-03 | 34 | 60 | 26 early |
| Microsoft | 10-K | 2023-06-30 | 2023-07-27 | 27 | 60 | 33 early |
| Walmart | 10-K | 2023-01-31 | 2023-03-17 | 45 | 60 | 15 early |
| Autodesk | 10-K | 2024-01-31 | 2024-06-10 | 131 | 60 | **70 late** |
| Super Micro | 10-K | 2024-06-30 | 2025-02-25 | 240 | 60 | **180 late** |
| 3D Systems | 10-K | 2023-12-31 | 2024-08-13 | 226 | 60 | **166 late** |

The weekend roll works: Autodesk's period ends 2024-01-31, +60 days is
2024-03-31, a Sunday, and the model rolls it to Monday 2024-04-01. All three late
filings are genuine: each of these companies publicly delayed the annual report
in question, and the model's margin matches the delay. *Why* each was delayed is
not established here and is not needed, what is being checked is the arithmetic,
not the cause. The extreme tail is equally real rather than artefactual: the ten
most negative median margins belong to Nutra Pharma, Party City, Avaya,
Veradigm, Latch, TuSimple and similar, delinquent filers and Chapter 11 cases
catching up on years of missed reports, not calculation errors.

But the late rate is roughly half an artefact, and §3.3's flag does not know
it. The model reads 8,371 filings (11.97%) as late. That is high against the
real-world rate, so it was checked, and the check found the exception the rules
carry:

**Rule 12b-25** grants an automatic extension, 15 calendar days for an annual
report, 5 for a quarterly, to a filer that files Form 12b-25 saying it cannot
file on time. A report filed inside that window is **deemed timely**. The
signature is directly visible in the lag histogram for non-accelerated 10-Ks:
a spike of 994 filings at exactly day 90, then a second cluster of 232 at day 105
and 326 at day 107, which is day 90 plus the 15-day extension.

| | Filings | % |
|---|---|---|
| Late against the statutory due date | 8,371 | 11.97 |
| Of which, inside the Rule 12b-25 window | 3,856 | 5.51 |
| **Late after the extension** | **4,515** | **6.46** |

46% of the filings §3.3 reads as late were probably not late. The correct
statement is a range, not a number: 6.46% is a lower bound and 11.97% an upper
bound, and the dataset cannot narrow it, because Form 12b-25 (NT 10-K / NT 10-Q)
carries no XBRL financial data and so does not appear in the SEC Financial
Statement Data Sets at all. There are no NT forms in `dim_filing` to join to.
Filing inside the window is necessary but not sufficient evidence that the
extension was invoked.

Federal holidays cost about 290 more. The model rolls weekend due dates and
states that it does not model holidays, calling the effect small and one-sided.
That is checkable and the model is right, though the effect is more concentrated
than "small" suggests. Of 913 filings flagged exactly one day late, **236 share
a single due date: 2024-11-11, Veterans Day**, a Monday when EDGAR was closed.
Another 52 fall on Martin Luther King Day in 2023 and 2024. Roughly 290 late
flags, 3.5% of all of them, are holiday artefacts, and 236 of those come from
one date. `dim_date` carries no holiday flag, so the fix is a dimension change
rather than a model change, and it is not made here.

The tightest decile is not what its label implies. `fil_deadline_filers`
ranks companies by median margin ascending and calls decile 1 the tightest
margin. Checking its composition: **all 642 companies in decile 1 have a
negative median margin.** Not one of them files on the wire; every one of them
typically files late. The genuinely disciplined companies, median margin 0 or 1
day, are in deciles 2 and 3. The decile ordering conflates "files exactly at the
deadline" with "chronically delinquent" because it treats late as merely a
smaller margin, which is the same conflation the `is_deadline_filing` flag makes
deliberately and correctly for its own purpose, carried into a ranking where it
does not belong. The ranking is retained as shipped, with this caveat, rather
than silently re-cut; a consumer wanting deadline discipline should filter on
`n_late_filings = 0` first, which leaves 900 habitual companies.

Seven of §3.4's 103 material changes are artefacts, not restatements. The
same skepticism §2.7 applied to restatements applies to the values feeding this
comparison, and two classes turn up.

*Sign-convention alternation.* Spirit AeroSystems reports FY2023 `NetIncomeLoss`
across four successive filings as:

| Filed | Value |
|---|---|
| 2024-02-22 | −$616,200,000 |
| 2024-11-05 | +$616,200,000 |
| 2025-02-28 | −$616,200,000 |
| 2025-10-31 | +$616,200,000 |

The magnitude never moves. The sign alternates with which filing last touched
it, which is the XBRL negated-label defect §2.7 documented as a class, the
company's loss did not become a profit and then a loss again. Because the
point-in-time view sees only the first of these and the latest view resolves to
the fourth, the model reads a restatement from top quartile to bottom. Energy
Focus and Transuite.org are the same defect. **3 of 103.**

*Transient single-filing outliers.* Axon Enterprise's FY2023 revenue is reported
as $1,563.4M in the 10-K filed 2024-02-27, then **$343.0M** in the 10-Q filed
2024-05-07, then $1,560.7M in every filing thereafter. The middle value is a
one-quarter figure carrying `qtrs = 4` and a period end of 2023-12-31, a source
tagging error, not a revision. The point-in-time view resolves to the latest
filing visible at the cutoff, which is the bad one, and Axon reads as moving
from the bottom growth quartile to the top. Counting cases where an *earlier*
filing visible at the cutoff agrees with the latest value to within 1% while the
value the model picked does not: **4 on revenue and 2 on net income.**

Netting the overlap, **7 of the 103 material changes are identifiable artefacts
and 96 survive.** The headline in §3.4 should be read as 96–103 depending on
whether the artefact classes are excluded, and the direction of the correction is
downward. This is a smaller correction than §2.7's ~16%, and the reason is
structural rather than reassuring: §3.4 operates on four tags at consolidated
level in USD, which excludes most of the classes §2.7 found, no share counts, so
no reverse splits; no foreign currency, so no IAS 29 re-presentation.

A defect in the attribution column that does not reach the headline.
`own_values_changed` tests the three input values with `is distinct from`, which
has no tolerance. 39 of the 323 companies it flags have all three inputs agreeing
to within 0.1%, QXO's revenue is $54,516,941 in one view and $54,517,000 in the
other, the precision re-reporting §2.7 documented. Those 39 are labelled
`own_values_restated` when nothing was restated. Only **one** of them appears in
the 103 material changes, so the headline is unaffected, but the attribution
column overstates restatement by roughly 12% of its own count. §2's 0.001
rounding threshold should be applied here and is not.

What verification did not cover. Values were checked against the loaded data,
never against source filings on EDGAR. Peer group construction was not
independently reproduced, only the visibility rule feeding it. The margin
threshold in §3.3 and the materiality bound in §3.4 were both derived from
observed distributions in this dataset and have not been tested against another
period. §3.2's negative result was not verified further, because there is nothing
to sample: no series was flagged, and confirming an absence of trend would
require data outside the loaded range.

---

### 3.6 Limitations

§3.3's late-filing rate is a range, not a number. 6.46% to 11.97%, and the
dataset cannot narrow it because Form 12b-25 carries no XBRL and is absent from
the source. Every count in §3.3 derived from `is_late_filing` inherits this,
including the 794 habitually-late companies and the composition of decile 1.

Three deadline exceptions beyond 12b-25 are not modelled. Federal holidays
(~290 filings, measured in §3.5). Newly public companies, whose first 10-Q is due
45 days after the registration statement's effective date rather than 45 days
after period end, and whose first 10-K is due 90 days regardless of the size
classification the model reads from `afs`, neither is detectable without
registration data this project does not load. Transition-period reports: 41
10-KTs exist in `dim_filing` and are excluded from §3.3 entirely rather than
given a deadline the rules do not define for them.

Filer status is taken as filed and is not verified. The 60/75/90 assignment
rests entirely on the SEC's `afs` field as the filer reported it. A company that
misreports its own accelerated-filer status is measured against the wrong
deadline, and nothing here detects that. `3-SRA` and `5-SML` do not occur in the
loaded range, so the model's `else` branch resolves only genuine non-accelerated
filers, but that is an observation about this data rather than a guarantee.

§3.4 rests on four tags and one cutoff date. Revenue under three tags plus
`NetIncomeLoss`, consolidated, USD, `qtrs = 4`. A company reporting revenue under
a fourth tag, in a foreign currency, or only at segment level is absent from the
population. The 2024-06-30 cutoff is a single point: the 103 is what eighteen
months of subsequent filings did to one fiscal year viewed from one date, and a
different cutoff would produce a different count. The direction is predictable:
an earlier cutoff sees fewer filings and would find more change, but the
magnitude is not established, and no sensitivity across cutoffs was run.

The two-view comparison inherits everything §2.8 says about restatements.
`pit_peer_comparables` observes that the best-known value changed; it cannot
observe why, and the four indistinguishable events §2.8 lists, error correction,
reclassification between tags, retroactive re-presentation, scale change, are
equally indistinguishable here. §3.5 removes the two classes that leave a
signature in these four tags. The general case is unquantified, as it is in §2.

`dim_company`'s 7% spurious version transitions (§2.8) reach §3.4's SIC
attribution. The range join that resolves each company's SIC as of each view's
date passes through those versions. The effect should be nil, spurious versions
carry the same SIC as the versions either side, so a major-group assignment is
unaffected, but the 19 reclassifications were not individually traced through
the SCD2 to confirm each is a real SIC change rather than a versioning artefact.

3,441 companies is a fraction of the 8,693 in the warehouse. The population
is narrowed by the annual period window, the four tags, positive revenue in both
the target and prior year, presence in both views, and the 20-peer minimum. The
2.99% material-change rate is a rate over companies that survive all of those
filters, which skew toward larger and more consistently reporting filers. It is
not a rate over all SEC registrants, and applying it to one would understate the
effect if anything, since the excluded companies report less consistently.

§3.2 establishes a negative that a longer series might overturn. Twelve
quarters, six series, no slope clearing r² = 0.5. A real drift of under a day per
year is entirely compatible with these results.

Nothing in §3 is confirmed against source filings on EDGAR. As in §1 and §2.
The known-filing checks in §3.5 are against public knowledge of those companies'
reporting delays, not against the filings themselves.

---

## §4 What point-in-time discipline is worth (Stage 4)

**Report date:** 2026-09-01
**Models:** `feat_filing_base`, `feat_filing_pit`, `feat_filing_naive`
**Script:** `scripts/train_compare.py`
**Tests:** `assert_feature_tables_aligned`,
`assert_pit_features_exclude_future`

### Scope

§3.4 showed that using restated figures for a historical comparison moves one
company in thirty-three into a different performance quartile. That is a
statement about a ranking. This section asks the same question about a
prediction, where the cost is easier to price: **two feature tables, the same
filings, the same label, the same model, differing only in what the features were
allowed to see.**

The deliverable is the distance between the two test AUCs. It is not the model.
The model is deliberately trivial, standardised inputs into scikit-learn's
default logistic regression, no tuning, no regularisation search, no class
weighting, no feature engineering beyond what the SQL already did. A better
model would raise both numbers. What is being measured is how much apparent skill
is manufactured by computing two features over the whole loaded range instead of
as of the filing date, and that survives the model being poor.

**Population.** 58,726 filings: every 10-K and 10-Q in the loaded range, originals
only, filed early enough to have a complete observation window. Amendments are
excluded because they are the revisions being predicted.

**Label.** A filing is restated if it published a consolidated figure, `segments`
and `coregistrant` both empty, that a later filing revised within 180 days.
11.65% of the population qualifies.

**Split.** Train on filings filed before 2025-01-01 (47,672 filings, 11.22%
restated), test on filings filed on or after it (11,054 filings, 13.51%
restated). Never a random split. These are panel data: the same company files
every quarter, so a random split puts a company's 2024 filings in train and its
2023 filings in test and the model learns to recognise the company.

**The five features**, identical in name and meaning in both tables:

| | Feature | Differs between tables? |
|---|---|---|
| 1 | `filing_lag_days` | no |
| 2 | filer status, as three indicators | no |
| 3 | `custom_tag_share` | no |
| 4 | `prior_restatement_count` | **yes** |
| 5 | `sector_restatement_rate` | **yes** |

The first three are properties of the filing as published and read the same
either way. They are the control: whatever accuracy survives on point-in-time
features is mostly theirs.

Features 4 and 5 have a history, and that is where the two tables part:

- **`feat_filing_pit`** admits a revision on the day that revision was
  *published*. Its sector rate is an expanding window over filings of the same
  SIC major group, as recorded on the `dim_company` version current at filing,
  and counts only those filings whose own observation window had already closed.
- **`feat_filing_naive`** computes both over the whole loaded range. Four things
  leak across the two features: the sector is read from the `dim_company`
  version current today, joined on `is_current` rather than range-joined on
  `filed_date`; the sector rate spans filings made after this one; it also
  includes the filing being scored; and the prior-restatement count spans every
  one of the company's revised filings, the scored filing included.

How much of that a working modeller would actually write is hypothesised, not
established, and no survey was done. Two of the four are the path of least
resistance, `is_current` is the easy join and a whole-window `group by` is the
easy aggregate. The `prior_restatement_count` construction is harder to defend
that way, because the identifier says *prior* and the code does not, and 4.2
shows it is the one carrying almost all of the effect. The gap should be read as
what these two specific constructions are worth, which is what 4.5 says as well.

Nor is a missing date predicate the whole of the difference, though it is the
largest part of it. Adding `filed_date <` the scored filing's date to the sector
rate would fix two of the four and still be wrong: it would put filings still
inside their own observation window into the denominator as clean ones.
`feat_filing_pit` dates each contribution at `filed_date + horizon` for exactly
that reason. The point-in-time table is a different construction, not this one
with a `where` clause.

### The horizon is not optional

The label needed a fixed horizon before anything else could be measured. Without
one, the share of 10-K and 10-Q filings ever restated runs:

| Filed quarter | Ever restated |
|---|---|
| 2023Q1 | 62.1% |
| 2023Q4 | 47.8% |
| 2024Q4 | 43.0% |
| 2025Q1 | 19.7% |
| 2025Q4 | 0.7% |

That gradient is not filer behaviour. It is elapsed observation time: the loaded
range ends 2025-12-31, so a filing from late 2025 has had no opportunity to be
revised. Since the test period *is* the censored region, an uncapped label would
have had the model largely measuring how long each filing had been watched.

Capping the window at 180 days makes the label mean the same thing in every
quarter, at the cost of dropping filings within one horizon of the end of the
range. The residual seasonality, Q1 filings restate more, because they are
annual reports, is real and is present in both splits.

180 days is a judgement call, and it is the only one that matters here. §4.3
rebuilds the whole comparison at five horizons and finds the gap does not turn on
it. A second materiality bound was tested and abandoned: requiring the revision to
exceed five percent of the original value moves the positive rate from 11.44% to
9.41%, which is almost nothing. The horizon, not the magnitude, is what makes
this label mean something. Counting segment-level and subsidiary-level revisions
as well would raise the positive rate from 11.65% to 20.75%, most of that being
re-tagging of dimensional breakdowns rather than revision of the headline
financials the label is meant to name.

### 4.1 The result

`scripts/train_compare.py`, run against both tables:

| Training rows | Feature set | Train AUC | Test AUC |
|---|---|---|---|
| all 47,672 | point-in-time | 0.6487 | **0.5894** |
| | naive | 0.7139 | **0.7172** |
| | **gap** | 0.0652 | **0.1278** |
| warm-up dropped, 34,156 | point-in-time | 0.6604 | **0.6102** |
| | naive | 0.7407 | **0.7218** |
| | **gap** | 0.0803 | **0.1116** |

Between 0.11 and 0.13 of test AUC is information from after the filing date.
Stated as a range rather than a number, for the reason 4.2 gives.

Read against the scale: the point-in-time model is 0.59–0.61, which is weak but
real, an honest reading of a hard problem with five crude features. The naive
model is 0.72, which reads as a usable early-warning screen. The distance between
"weak but real" and "usable" is entirely the leak. Nothing about the naive model's
output marks it: same rows, same label, same code path, same five column names.

### 4.2 Where the gap comes from

Each feature scored alone on the test split, as a raw ranking with no model
fitted, alongside its fitted coefficient on standardised inputs:

| Feature | PIT coef | PIT AUC alone | Naive coef | Naive AUC alone |
|---|---|---|---|---|
| `filing_lag_days` | 0.0881 | 0.6981 | 0.1126 | 0.6981 |
| `is_large_accelerated_filer` | −0.1688 | 0.5428 | −0.1657 | 0.5428 |
| `is_accelerated_filer` | −0.0204 | 0.5107 | −0.0169 | 0.5107 |
| `is_non_accelerated_filer` | 0.1727 | 0.5536 | 0.1677 | 0.5536 |
| `custom_tag_share` | 0.2177 | 0.5887 | 0.1857 | 0.5887 |
| `prior_restatement_count` | −0.0058 | 0.5669 | **0.5781** | **0.7180** |
| `sector_restatement_rate` | −0.2025 | 0.5526 | 0.1786 | 0.5562 |

The leak is almost entirely one feature. `prior_restatement_count` computed
over the full window scores 0.7180 on its own, higher than the entire fitted
naive model, and it carries by far the largest coefficient in it. The same
feature computed point-in-time scores 0.5669 and the model gives it a coefficient
of −0.0058, which is to say it finds nothing there.

The mechanism is not subtle once stated. The full-window count includes the
filing being scored: a company's revised filings are counted across the whole
range, so the very restatement that sets the label is one of the events counted.
On the test split its median is 7 for restated filings against 4 for clean ones.
It is less a feature than a smeared copy of the answer.

The naive **sector** rate leaks far less, 0.5562 against the point-in-time
0.5526, but it does leak twice over. It is computed self-inclusively across
filings made after this one, and it groups on the filer's present-day SIC:
1,330 filings by 268 companies sit in a different SIC major group under the two
readings, so those filings are scored against peers they had not yet joined.

The point-in-time sector rate has a warm-up problem. The gap is quoted as a
range because the point-in-time model is handicapped by something other than
the leak. For the first months of the loaded range the sector rate has no
resolved history to read and correctly falls back to a whole-market rate that
is itself near zero, while those early filings are annual reports and restate
more than average:

| PIT sector rate quintile | Train label rate | Test label rate |
|---|---|---|
| 1 (lowest) | 16.01% | 8.86% |
| 2 | 10.01% | 12.26% |
| 3 | 8.24% | 16.55% |
| 4 | 11.64% | 14.34% |
| 5 (highest) | 10.20% | 15.52% |

In training the relationship runs backwards; in test it runs the right way. The
model fits a negative coefficient (−0.2025) to the confound and carries it into
a period where the sign has flipped. That is a defect of the point-in-time
construction over a short loaded range, not of point-in-time discipline, and it
depresses the point-in-time test AUC.

The second training regime drops the 13,516 filings whose sector rate had no
history to compute from. The filter is applied to **both** feature sets
identically and never to the test set, so the two models stay comparable and the
test population is the same in every row of 4.1. The point-in-time model gains
0.021 of test AUC; the gap narrows from 0.1278 to 0.1116 and does not close.

### 4.3 Does the gap depend on the horizon?

180 days is a judgement call, so the whole comparison was rebuilt at five
horizons. Only `restatement_label_horizon_days` changes; the population, the
label, both feature tables and the two singular tests all follow from it.
All 21 tests pass at every horizon.

| Horizon | Test filings | Test window | Test positive | PIT test AUC | Naive test AUC | Gap |
|---|---|---|---|---|---|---|
| 90 | 16,674 | to 2025-10-02 | 6.71% | 0.5802 | 0.6951 | **0.1149** |
| 120 | 16,227 | to 2025-09-02 | 9.35% | 0.5769 | 0.7042 | **0.1273** |
| **180** | **11,054** | **to 2025-07-03** | **13.51%** | **0.5894** | **0.7172** | **0.1278** |
| 240 | 6,880 | to 2025-05-05 | 19.30% | 0.6236 | 0.7535 | **0.1299** |
| 270 | 5,277 | to 2025-04-04 | 23.69% | 0.5600 | 0.7275 | **0.1675** |

Same, with warm-up rows dropped from both models' training sets:

| Horizon | 90 | 120 | 180 | 240 | 270 |
|---|---|---|---|---|---|
| Gap | 0.0952 | 0.1087 | 0.1116 | 0.1090 | 0.1457 |

The gap does not turn on the horizon. Across 90 to 240 days it sits between
0.115 and 0.130 on all training rows, and between 0.095 and 0.112 with warm-up
dropped, a spread narrower than the correction for the warm-up artefact itself.
The headline range quoted in 4.1 is not an artefact of choosing 180.

The 270-day row is reported and discounted. Its gap is the largest in the
table, but its test set is 5,277 filings ending 2025-04-04, a single quarter,
and the annual-report quarter at that, with a 23.69% positive rate against
13.51% at 180. The point-in-time model is the half that moves (0.5600, the
lowest anywhere in the table) while the naive model holds up, which is what a
small single-season test set does to the weaker of two models. It is one point
on five, and no trend is claimed from it.

The horizon and the seasonal mix cannot be separated here, and that limits what
this table establishes. A longer horizon eats the test set from the front, so
the surviving test window is not just shorter but earlier and progressively more
Q1-heavy, 90 days leaves three quarters of 2025, 270 leaves one. Test positive
rate rises monotonically down the table for that reason as much as for the longer
observation window. The stability of the gap across the first four rows is
therefore stronger evidence than any reading of its slope.

The leak stays in the same place at every horizon. `prior_restatement_count`
computed over the full window scores, alone, within a few points of the entire
fitted naive model at all five:

| Horizon | 90 | 120 | 180 | 240 | 270 |
|---|---|---|---|---|---|
| Naive `prior_restatement_count` alone | 0.6868 | 0.7033 | 0.7180 | 0.7399 | 0.7445 |
| Whole fitted naive model | 0.6951 | 0.7042 | 0.7172 | 0.7535 | 0.7275 |
| Same feature, point-in-time | 0.5268 | 0.5505 | 0.5669 | 0.5927 | 0.5999 |

Both readings of the feature strengthen as the horizon lengthens, which is what
should happen, a longer window makes prior revisions a genuinely better signal,
and it also gives the full-window count more of the label to copy. The distance
between the two readings is what does not move.

### 4.4 Verification

The two tables are provably the same experiment.
`assert_feature_tables_aligned` full-outer-joins them on `adsh` and fails on any
filing present in one and not the other, or labelled differently between them.
It passes: 58,726 rows either side, zero label disagreements. Without that, the
two models would be answering different questions and the gap would be an
artefact of the population. `scripts/train_compare.py` re-checks the same
invariant in Python before fitting anything, and raises rather than reporting a
number it cannot defend.

The point-in-time features were recomputed the slow, obvious way. Both are
built by a running sum over a sorted union of query rows and event rows, which is
one sort instead of 58,726 lateral lookups but is not obviously correct by
inspection, the strictly-prior semantics rest entirely on query rows sorting
before same-day events. `assert_pit_features_exclude_future` rebuilds both
features with the date predicate written out as a range join and compares row by
row across all 58,726 filings. It passes.

It did not pass first time. The initial run returned 1,257 disagreements, all of
them filings carrying no numeric SIC. Those share a single null window partition,
so the running sum accumulated a count over them that backed no rate, the rate
itself correctly fell through to the market fallback, but the reported support
column overstated it, and `train_compare.py` reads that column to identify
warm-up rows. The diagnostic was wrong and the warm-up mask was reading 1,257
rows as having sector history they did not have. Fixed by guarding the diagnostic
with the same null test the rate already used. The 4.1 figures are post-fix; the
pre-fix warm-up regime trained on 35,076 rows rather than 34,156 and reported a
gap of 0.1115 against 0.1116.

`prior_restatement_count` was exact on all 58,726 rows in both the failing and
passing runs. The single feature carrying the leak has been independently
recomputed and agrees.

The comparison is deterministic. `lbfgs` on fixed inputs with no sampling
step; two consecutive runs of `train_compare.py` produce byte-identical output.

No pandas. Rows come out of Postgres into numpy arrays. Every aggregation in
this section is SQL.

### 4.5 Limitations

The model is bad, and that is the design, but it does constrain the reading.
Five crude features and an unregularised linear fit. The fitted point-in-time
model scores *below* `filing_lag_days` used alone (0.5894–0.6102 against 0.6981),
because filing lag is correlated with filer status and the linear fit spreads one
signal across collinear columns while the sector confound pulls in the wrong
direction. A gap measured between two better models would not be this gap. The
direction is not in doubt; the magnitude is specific to this model.

The gap is a property of these two constructions, not of leakage in general.
`feat_filing_naive` is one plausible naive table. A modeller who computed the
prior-restatement count with a date predicate but got the sector rate wrong would
leak far less; one who added more full-window aggregates would leak more. 0.11 to
0.13 is what these five features are worth, not a constant.

The test period is six months. 2025-01-02 to 2025-07-03, the whole of the
loaded range that has both a complete 180-day observation window and a filing
date after the training cutoff. It contains one annual-report season, and Q1 is
the highest-restatement quarter. A test set spanning a full year would weight the
seasonal mix differently. §4.3's sweep cannot fix this and partly inherits it:
horizon and seasonal mix move together, because a longer horizon leaves a shorter
and more Q1-heavy test window.

The warm-up defect would shrink with more history and cannot be removed here.
It exists because the loaded range starts 2023Q1 and the sector rate needs
resolved filings before it says anything. Loading 2019–2022 would push the warm-up
entirely outside the training window. The second training regime bounds the
effect rather than eliminating it.

Right-censoring is handled by exclusion, not by modelling. Filings within 180
days of the end of the range are dropped rather than treated as censored
observations. That is the correct simple choice, and it is not free.
A survival model would use them; this is not a survival model. 11,230 of the
69,956 10-K and 10-Q filings in the loaded range are dropped this way, all of
them from the second half of 2025.

The label inherits everything §2.8 says about restatements. It is built on
`int_restatements`, which observes that a value changed and cannot observe why.
Error correction, reclassification between tags, retroactive re-presentation and
scale change are equally indistinguishable here, and no attempt is made to
separate them. A filing labelled restated is a filing whose consolidated figure
moved, nothing more.

Nothing here is confirmed against source filings on EDGAR. As in §1, §2
and §3.
