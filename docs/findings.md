# Findings

**Report date:** 2026-08-28
**Data vintage:** SEC Financial Statement Data Sets, 2023Q1–2025Q4, downloaded 2026-08-23
**Dataset:** 81,720 filings · 42,797,341 numeric facts
**Environment:** PostgreSQL 16.15 · dbt-core 1.12.3 · dbt-postgres 1.11.0 · Python 3.12.14
**Commit:** 703e1e3
**Author:** Alexander Burfoot

Every figure in this document is reproducible from the repository at the commit
above by running `make up && make fetch && make load && dbt build`, then querying
the models under the `analysis` schema.

---

## Executive summary

Eight data quality rules were applied to twelve quarters of SEC XBRL filing
data. One result organises the rest.

**1. Data quality grades sharply with filer size.** Non accelerated filers (the
smallest SEC size category) fail an average of 0.54 quality rules against 0.10
for accelerated and 0.07 for large accelerated filers, roughly eight times
worse. Four independent measures agree: extension tag usage, unit type inconsistency,
balance sheet violations, and aggregate rule failures. All twelve
material balance sheet violations come from non accelerated filers.

**2. Defects are concentrated, not systemic.** 69% of the 8,693 filers examined
fail no rule at all, 27% fail exactly one, and only three fail three or more.
This is a minority of filers problem rather than a data source problem, which
makes filer level screening more effective than blanket filtering.

**3. Missing values dominate every other defect by volume.** 4.4% of reported
facts carry a tag, a period and a unit but no number. This affects 1.9 million rows. 
Every other rule tested affects under 0.1%.

**4. Company specific extensions underperform on three separate measures.**
They carry a null rate 2.9 times that of standard tags, they are
disproportionately used by smaller filers, and they account for nearly all unit
inconsistency: Where a tag is used with both currency and non currency units
(measuring a share count for one filer and a dollar amount for another) 
3,656 of 3,675 such tags are company extensions rather than standard taxonomy elements.

**5. Amendments arrive roughly 140 days after the original filing.** Median lag
from period end is 67 days for a 10-K and 207 days for a 10-K/A. A consumer
acting on a reported figure has months of exposure before a revision could exist,
with no signal in the original that one is coming.

**6. The SEC's documented natural key is incomplete for post 2022 data.**
Uniqueness testing on the documented key produced 4,635,667 violations.
Including the 'segments' column reduced this to 154 genuine duplicates carrying
conflicting values within a single filing.

Root causes are labelled as established, hypothesised, or not established. None
are confirmed against source filings.

---

## §1 — Data quality of SEC XBRL filings

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
| Referential integrity | Yes | Every numeric fact joins to a filing — **no violations found** |
| Uniqueness | Partial | Tested against the natural key; see §1.6 on the key itself |
| **Accuracy (external)** | **No** | Requires an independent source of truth for the same figures |
| **Semantic correctness** | **No** | Whether a filer chose the *right* tag is not assessable from this data |

Two absences are worth stating plainly.

**External accuracy is untested.** Nothing in this dataset reveals whether a
reported revenue figure is correct. §1.10 tests one internal identity that must
hold by construction, but confirming accuracy generally would require
reconciling against audited statements or a second commercial data source.

**No across filing reconciliation was performed.** A figure reported for a
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
the observed gap distribution — see §1.10.

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
and amended annual reports arrive at a median of 207 days which is roughly 140 days
after the original. Anyone acting on a reported figure therefore carries about
four months of exposure before a revision could plausibly exist, with nothing in
the original filing to signal that one is coming. The lag also scales with filer
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

**Multi currency reporting is not an error.** Tags such as `Assets` appear under
43 different currency codes because foreign private issuers report in their home
currency. That is correct reporting. It does mean these tags cannot be summed
across filers without FX conversion, a naive aggregate adds yen to euros.

**Mixed unit *types* are a different matter.** Where one tag carries both
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

**The split by tag type is the substantive finding:**

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

**Abstract tags are not the explanation.** These are presentation only section
headers that carry no value by design and would have diluted the rate if
present. None appear in the fact table at all. They are abstract elements
that live in the presentation file, not the numeric one. The 4.44% needs no adjustment.

**Custom tags are substantially has a higher proportion of null values than standard ones.**

| Tag type | Facts | Nulls | % null |
|---|---|---|---|
| Standard taxonomy | 39,058,779 | 1,488,920 | 3.81 |
| Company extension | 3,738,562 | 409,985 | 10.97 |

Company specific extensions carry a null rate 2.9 times that of standard
taxonomy elements. Extensions are 8.7% of facts but 21.6% of nulls. This is the
third distinct way extensions underperform, after non comparability (§1.3) and
unit type inconsistency (§1.4), a filer defining its own element is more likely
to leave it empty than to leave a standard one empty.

**The rate is also concentrated by filer.** Several companies in §1.11 report
null rates above 40%. HYPERSCALE DATA is at 42.1%. FOXO TECHNOLOGIES is at 40.7%.
PROPANC BIOPHARMA is at 40.4%. These values are against the 4.44% population rate.
The defect is driven by a subset of filers rather than spread evenly across the source.

**Root cause is not established.** The candidates are a filer tagging a line
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

They concentrate in derivative disclosures which are: `DerivativeLiabilityNotionalAmount`,
`DerivativeAssetFairValueGrossLiability`, and in a small number of filers.

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

Such a row cannot be repaired reliably as there is no way to know which field the
stray tab split, so they are rejected and counted rather than silently dropped
or half-parsed.

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
| DQ-01 | Null numeric value | High | 1,898,905 | **High** — the only defect large enough to move an aggregate | Consumer |
| DQ-02 | Reporting duration exceeds ten years | High | 951 | **Medium** — low volume, but each instance is nonsense if aggregated | Consumer |
| DQ-03 | Duplicate key with conflicting values | High | 300 | **Medium** — produces non deterministic query results | Consumer |
| DQ-04 | Rejected at load: embedded delimiter | Medium | 236 | **Low** — negligible volume, but invisible if not counted | Publisher |
| DQ-05 | Filing lag exceeds three years | Medium | 59 | **Low** — distorts timeliness benchmarks only | Consumer |
| DQ-06 | Filed before the period it reports | High | 4 | **Low** — negligible volume, but undermines trust in the date fields | Filer |

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

*Recommended action:* do not deduplicate by arbitrary selection — picking one of
two conflicting values makes the result depend on physical row order. Either
exclude both rows and flag the key as unresolved, or escalate to the filing
itself for manual resolution where the figure is material to the analysis.

**DQ-04: Rejected at load: embedded delimiter**

*Root cause: established.* Free text fields in the SEC's published files contain
literal tab characters, producing more fields than the file's own header
declares. This is a defect in the published artefact, not in what companies
reported.

*Recommended action:* retain the current handling — reject the row, count it,
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

**What is not covered here.** No root cause is confirmed by inspection of source
filings; all are inferred from the aggregate data. No estimate of financial
materiality is offered, since that would require assumptions about downstream
use that this analysis does not make. Remediation ownership is assigned on where
the defect originates, not on any formal data ownership model.


---

---

### 1.9 Verification

A finding is a query result until someone inspects it. Instances of the three
high-severity event-based rules were sampled and reviewed individually.

| Rule | Population | Sampled | Confirmed | Uncertain |
|---|---|---|---|---|
| DQ-06 Filed before period end | 4 | 4 | 4 | 0 |
| DQ-02 Duration exceeds ten years | 951 facts | full population by band | 15 | 936 |
| DQ-03 Conflicting duplicates | 154 groups | 20 | 20 | 0 |

**DQ-06: all four confirmed, and none are ordinary filings.** PowerSchool
Holdings filed a 10-Q on 2024-05-07 for a period ending 2024-12-31, 238 days in
the future; Power REIT the same, 235 days. The other two are not periodic
reports at all — an S-4/A registration amendment and a 6-K foreign issuer
report. In every case `period` carries a fiscal year end that had not yet
occurred rather than the period actually reported on. The defect is real, but it
is better described as a field semantics problem than a date error: `period`
does not always mean what a consumer would assume.

**DQ-02: the threshold is too aggressive and most flagged rows are probably
legitimate.** Splitting the 951 facts by duration:

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

This is a false positive finding against my own rule. The `qtrs > 40` bound was
chosen to sit clear of normal reporting, and it does, but it does not sit clear
of *unusual but valid* reporting. A consumer wanting only genuine defects should
use a far higher bound. The rule as stated is retained, with this caveat, rather
than silently retuned.

**DQ-03: All twenty confirmed, and the gaps are not rounding.** The sampled
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

**What verification did not cover.** The rate-based rules (DQ-01 nulls, custom
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

**Coverage.** 166,270 consolidated balance sheets were assembled across 8,252
companies. 156,618 (94.2%) carry the filer's own reported
`LiabilitiesAndStockholdersEquity` total and can be tested directly.

**Threshold, chosen from the distribution.**

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

**Result.** 99.92% of testable balance sheets balance exactly. This is the first
rule where the data overwhelmingly passes, which is worth stating in a report
otherwise listing defects.

Twelve filings exceed the threshold. **All twelve are non accelerated filers.**
The largest is a shell sized balance sheet reporting $5 in assets against $5,379
in liabilities and equity. One company, NEXT MEATS HOLDINGS, appears twice — as
a 10-Q and its own 10-Q/A amendment, carrying the identical imbalance. The
amendment did not correct it.

**A check that does not work.** The same identity can be tested by summing
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

**Limitations.** Consolidated USD figures only; segment and subsidiary
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

**Defects are concentrated, not systemic.** Seven filers in ten fail nothing.
Only three of 8,693 fail three or more rules. This is a minority-of-filers
problem, which makes filer-level screening a more effective remediation than
blanket filtering — a materially different recommendation from what the raw
counts alone would suggest.

**Quality grades with filer size.**

| Filer status | Filers | Mean rules failed | Failing 3+ |
|---|---|---|---|
| Non-accelerated | 4,901 | 0.54 | 3 |
| Accelerated | 1,069 | 0.10 | 0 |
| Large accelerated | 2,535 | 0.07 | 0 |

Non accelerated filers fail roughly eight times as many rules as large
accelerated filers. This is the fourth independent measure pointing at the same
population — after extension tag share (§1.3), unit type inconsistency (§1.4),
and every balance sheet violation (§1.10). Four different checks, four times the
same answer.

**Repeat offenders.** The three filers failing three rules are REGEN BIOPHARMA,
THERAPEUTIC SOLUTIONS INTERNATIONAL, and NEXT MEATS HOLDINGS — all
non accelerated. NEXT MEATS also appears in §1.10, failing an independent
accuracy check as well as the completeness and comparability ones.

Null rates among the worst filers are extreme: 42.1% at HYPERSCALE DATA, 40.7%
at FOXO TECHNOLOGIES, 40.4% at PROPANC BIOPHARMA, against a 4.44% population
rate. This substantially qualifies §1.5. The missing value problem is driven by
a subset of filers rather than spread evenly.

One filer breaks the pattern. PENNANTPARK FLOATING RATE CAPITAL is large
accelerated and fails two rules, but on conflicting duplicate keys rather than
the null and extension profile that characterises the rest. A different failure
mode entirely.

**Limitations.** The two rate thresholds, twice the population null rate, and
20% custom tags, are chosen, not derived from the distributions. Event based
rules flag on a single occurrence, so a filer with one bad row ranks alongside
one with hundreds. Most importantly, the six rules are **not independent**:
custom tag usage and unit inconsistency measure related behaviour, so a filer
failing both has not necessarily failed two distinct things. The summed score
should be read as a rough ordering, not a measure.

---

## §2 — Restatements (Stage 2)

## §3 — Filing behaviour and comparables (Stage 3)
