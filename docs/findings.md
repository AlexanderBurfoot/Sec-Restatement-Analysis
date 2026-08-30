# Findings

**Report date:** §1 2026-08-28 · §2 2026-08-30
**Data vintage:** SEC Financial Statement Data Sets, 2023Q1–2025Q4, downloaded 2026-08-23
**Dataset:** 81,720 filings · 42,797,341 numeric facts · 426,706 detected restatements
**Environment:** PostgreSQL 16.15 · dbt-core 1.12.3 · dbt-postgres 1.11.0 · Python 3.12.14
**Reference point:** §1 at tag `v1-data-quality`; §2 at tag `v2-restatements`
**Author:** Alexander Burfoot

Every figure in this document is reproducible from the repository at the tag
above by running `make up && make fetch && make load && dbt build`, then querying
the models under the `analysis` and `marts` schemas.

---

## Executive summary

Twelve quarters of SEC XBRL filing data, examined twice over. §1 tests each
filing against itself with eight data quality rules. §2 tests filings against
each other, detecting where a company published one value for a figure and later
published another.

### Restatements (§2)

**1. Restatements do not arrive in amendments.** 426,706 revisions were detected
across 4.785% of the facts that could have been revised. Only **8.26% arrived in
a form ending in `/A`**. The other 91.7% arrived inside an ordinary 10-Q or 10-K
quietly carrying a revised comparative, at a median of **364 days** after first
publication, with no marker of any kind. Watching for amendments catches roughly
one restatement in twelve.

**2. Revisions concentrate on the statement people read.** The income statement
is revised at 7.29% of revisable facts against 4.27% for the balance sheet.
Earnings per share is the single most-revised concept in the dataset: **one in
ten reported EPS figures is later published at a different value.**

**3. Revision predicts revision.** A figure revised once has a 7.78% chance of
being revised again; revised twice, 17.82%; three times, 22.94%. Prior revision
count is a usable risk signal and needs no modelling beyond what ships here.

**4. Restating is normal, which inverts §1's central result.** 86.8% of companies
restate something and 54% do it in sustained runs. **96% of large accelerated
filers restate, against 88% of non-accelerated ones**, and large filers restate
40% more facts each. This is the opposite direction from the data quality gradient in
finding 7 below.

**5. Roughly one restatement in nine is not a revision of a value.** Three
categories were defined in advance and counted directly across the whole
population, with no sampling: **6,950 zero-origin** facts first published as zero,
**10,061 revisions above 10,000%**, and **29,118 sign flips** where the latest
value is the exact negation of the first. They are mutually disjoint and total
**46,129 10.81%** and each is a reclassification, a rescaling or a sign
correction rather than a changed number. Together with the classes found by
sampling (power-of-ten scale changes, precision re-reporting, IAS 29 hyperinflation
re-presentation) the identifiable artefacts reach about **16%** of the population,
which takes the 4.785% rate to roughly **4.01%**.

**6. The downward skew survives that, and strengthens.** 57.76% of revisions are
reductions. Sign flips have identical magnitudes either side, so their direction
means nothing; excluding them gives **58.51%**, and excluding all three artefact
categories gives **60.02%**. The artefact classes are themselves strongly upward,
so they were diluting the finding rather than causing it. What does *not* survive
unqualified is the revision *magnitude* distribution.

### Data quality (§1)

**7. Data quality grades sharply with filer size.** Non accelerated filers (the
smallest SEC size category) fail an average of 0.54 quality rules against 0.10
for accelerated and 0.07 for large accelerated filers, roughly eight times
worse. Four independent measures agree: extension tag usage, unit type inconsistency,
balance sheet violations, and aggregate rule failures. All twelve
material balance sheet violations come from non accelerated filers.

**8. Defects are concentrated, not systemic.** 69% of the 8,693 filers examined
fail no rule at all, 27% fail exactly one, and only three fail three or more.
This is a minority of filers problem rather than a data source problem, which
makes filer level screening more effective than blanket filtering.

**9. Missing values dominate every other defect by volume.** 4.4% of reported
facts carry a tag, a period and a unit but no number. This affects 1.9 million rows. 
Every other rule tested affects under 0.1%.

**10. Company specific extensions underperform on three separate measures.**
They carry a null rate 2.9 times that of standard tags, they are
disproportionately used by smaller filers, and they account for nearly all unit
inconsistency: Where a tag is used with both currency and non currency units
(measuring a share count for one filer and a dollar amount for another) 
3,656 of 3,675 such tags are company extensions rather than standard taxonomy elements.

**11. Amendments arrive roughly 140 days after the original filing.** Median lag
from period end is 67 days for a 10-K and 207 days for a 10-K/A. A consumer
acting on a reported figure has months of exposure before a revision could exist,
with no signal in the original that one is coming. §2 finding 1 sharpens this
considerably: amendment lag understates the exposure, because most revisions
never appear in an amendment at all.

**12. The SEC's documented natural key is incomplete for post 2022 data.**
Uniqueness testing on the documented key produced 4,635,667 violations.
Including the 'segments' column reduced this to 154 genuine duplicates carrying
conflicting values within a single filing.

Root causes are labelled as established, hypothesised, or not established. None
are confirmed against source filings.

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
or half parsed.

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

**What is not covered here.** No root cause is confirmed by inspection of source
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

**DQ-06: all four confirmed, and none are ordinary filings.** PowerSchool
Holdings filed a 10-Q on 2024-05-07 for a period ending 2024-12-31, 238 days in
the future; Power REIT the same, 235 days. The other two (an S-4/A registration
amendment and a 6-K foreign issuer report) are not periodic reports at all.
In every case `period` carries a fiscal year end that had not yet
occurred rather than the period actually reported on. The defect is real, but it
is better described as a field semantics problem than a date error: 'period'
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

**What verification did not cover.** The rate based rules (DQ-01 nulls, custom
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
in liabilities and equity. One company, NEXT MEATS HOLDINGS, appears twice. This is because
a 10-Q and its own 10-Q/A amendment, is carrying the identical imbalance. The
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
Only three of 8,693 fail three or more rules. This is a minority of filers
problem, which makes filer level screening a more effective remediation than
blanket filtering. This is a materially different recommendation from what the raw
counts alone would suggest.

**Quality grades with filer size.**

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

**Repeat offenders.** The three filers failing three rules are REGEN BIOPHARMA,
THERAPEUTIC SOLUTIONS INTERNATIONAL, and NEXT MEATS HOLDINGS. All are
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

**The rounding threshold is 0.001, one tenth of one percent** of the first
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

**Population.** 8,918,472 described facts were reported on more than one date and
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

**The question.** Do some industries revise their reported figures more than
others, once size is accounted for?

**What the query does.** `rst_by_sector` maps SIC codes to divisions and
two-digit major groups, then aggregates over `GROUPING SETS` at both levels plus
a grand total. Sector is taken from the `dim_company` SCD2 version current at
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

**The number.** Excluding the unclassified bucket, sector rates run from 4.11%
(Construction) to 6.88% (Agriculture), a spread of 1.7×. At major-group level
the spread widens to 3×, from 2.81% (major group 42, trucking and warehousing) to
8.60% (major group 14, mining of nonmetallic minerals).

**What it means.** The sector effect is real but modest, and it is much weaker
than §1's filer-size effect on data quality, which ran to 8×. Industry is not a
useful screen on its own: every division restates between 4% and 7% of its
revisable facts, and no sector is clean. Two secondary patterns are more usable
than the ranking. Finance, Insurance & Real Estate has both the second-lowest
rate (4.36%) and by far the lowest share of companies restating at all (79.66%
against 86.78% overall), so its restatements concentrate in fewer filers.
Manufacturing and Agriculture revise downward most often (62%), against 52% for
Finance, restatements in the goods-producing sectors are disproportionately
reductions.

**The unclassified bucket is an artefact and should not be read as a sector.**
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

**The question.** When a figure is revised, by how much, and does the revision
run in a systematic direction?

**What the query does.** `rst_magnitude_distribution` buckets every restatement
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

**The number.** The median revision is 42.4% of the original figure. A quarter of
all restatements fall in the 0–5% band, and another quarter exceed 100%.

**What it means.** Two things, and the second is more important than the first.

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

**The question.** Do revisions concentrate on particular financial statements, or
particular line items?

**What the query does.** `rst_by_statement` joins restatements to `dim_tag` for
statement placement. `int_restatements` is keyed on `tag` without
`taxonomy_version` while `dim_tag` is keyed on both, so the dictionary is first
collapsed to tag grain by modal statement across the versions that define the
tag; a tag placed on more than one statement is flagged
(`placement_is_ambiguous`) rather than quietly assigned. Denominator is again
revisable facts, so a tag reported on every filing does not accumulate
restatements by exposure alone. Statement and grand totals are computed over
every tag; only the tag-level detail is trimmed to the top 15, so a total is
never the sum of the rows displayed beneath it.

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

**The number.** The income statement is revised at **7.29%** of revisable facts,
1.7× the balance sheet's 4.27% and 6× supplementary information's 1.20%.

**What it means.** **Revisions concentrate on the statement people actually read.**
The income statement is the most revised, and within it the most-revised items are
the headline ones: revenue, operating income, and earnings per share. Earnings per
share is the single most frequently revised concept in the dataset at 10.5% of
revisable facts, one in ten reported EPS figures is later published at a
different value. Balance sheet items are comparatively stable, and `Assets`
specifically is revised at 7.04% but with a median revision of only 6.9%, the
smallest of any major tag.

Two caveats on this table, both material:

**The EPS medians of 200–300% are a small-denominator effect, not a measure of
error size.** Median first reported EPS among restated facts is $0.41 and the
median absolute change is $0.965, so a swing from $0.41 to −$0.55 registers as a
235% revision. EPS percentages are not comparable with revenue or asset
percentages and should not be pooled with them. The *frequency* (10.5%) is sound;
the magnitude is not.

**The ~95% medians on share-count tags are reverse splits.** See §2.7  47% of
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

**The question.** Do revisions bunch into particular quarters, or arrive at a
steady rate?

**What the query does.** `rst_clustering` asks the question on two clocks, because
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
| 2023 Q1 | 1,418 | 6,754 | 210.0 | — |
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

**The number.** From 2024 Q2 onward the rate holds between 6,392 and 7,929 per
1,000 filings (a band of −9% to +12% around a mean of 7,050. The apparent 39×
ramp from 2023 Q1 to 2024 Q1 is **not a finding) it is the detector warming
up.**

**What it means. Restatements do not cluster, and the section's main result is a
negative one.** A revision can only be observed if the original report is also inside the loaded window. In
2023 Q1 there is no prior data at all, so almost nothing *can* register as a
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

**The question.** Given that a figure has been revised once, is it more likely to
be revised again?

**What the query does.** `int_restatements` compares first value against latest,
which collapses a fact revised three times into a single row, it cannot answer
this question. `rst_amendment_chains` rebuilds the full report sequence and walks
it with a **recursive CTE**: each link is a material change from the *previous*
report rather than from the first, so a fact revised three times becomes one chain
of length three. The recursion carries the accession path and the value the chain
started from, neither of which a plain aggregate over the steps could produce in
order. The same collapse-and-tiebreak rule as `int_restatements` is used, so a
chain cannot count a revision the restatement model does not recognise.

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

**The number.** A fact that has been revised once has a **7.78%** chance of being
revised again. A fact that has been revised twice has **17.82%** 2.3× higher. A
fact revised three times has 22.94%.

**What it means. Yes, and strongly.** The hazard more than doubles after the
second revision and keeps rising. This is the most actionable result in §2: a
figure with two revisions already against it is not merely a figure that has
settled after some turbulence, it is a figure roughly three times more likely than
a once-revised one to move again. For a consumer, the number of prior revisions on
a fact is a usable risk signal, and it is available in `int_restatements` as
`n_reports` and `n_distinct_values` without any additional modelling.

Chain span is nearly constant at one year for lengths 1 through 6, which is the
§2 headline mechanism again: each additional link is one more annual comparative.

**Chain population reconciliation.** The chain model counts 441,020 chains against
426,706 restatements. The two populations are defined differently and the gap is
expected: chains count step-to-step departures, so a fact revised away and then
restored to its original value is a chain of length 2 but not a restatement at all,
since `int_restatements` tests first against latest. There are 16,829 such
revised-and-restored facts, which more than accounts for the 14,314 difference;
the offset in the other direction is multi-step chains whose individual steps fall
below the rounding threshold while the cumulative move does not.

**Filer concentration.** One company dominates: **Grupo Financiero Galicia** holds
2,721 chains of which 979 are length 3 or more, 36% long chains, against a
population-wide 1.39%. §2.7 establishes why, and it is not a control failure.

*Root cause: hypothesised.* Rising hazard is consistent with a subset of facts
being genuinely difficult to measure (estimates that keep being refined) rather
than with revision itself causing revision. This data cannot separate a persistent
per-fact propensity from a causal chain.

---

### 2.6 Serial restaters

**The question.** Which companies restate repeatedly, and is it a sustained run
of bad periods or an occasional scatter?

**What the query does.** `rst_serial_restaters` ranks filers by `NTILE(10)` on the
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

**The number.** The top decile, 697 companies, accounts for **32.67%** of all
restatements. The top two deciles account for 46.9%. And **4,685 companies, 54% of
all filers, show a sustained run of three or more consecutive restated periods.**

**What it means. Restating is normal, and that is the finding.** §1.11 found
defects concentrated in a minority of filers: 69% failed no data quality rule at
all. Restatements behave nothing like that. 86.8% of companies restate something,
54% do it in sustained runs, and the top decile holds only a third of the volume.
This is concentrated, but nowhere near the winner-take-all shape of the §1 defects.

**This inverts §1's central result, and the inversion is the most important
cross-section in the report.** Restatement volume is a *large*-filer phenomenon:

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

**These are not accusations of misreporting.** A large filer reports far more
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

§1.9's most defensible result came from checking a rule and finding it over-flagged
by 60×. The same skepticism is applied here, and it finds less than that but not
nothing.

**Method.** Twenty restatements were drawn from the 426,706 in reproducible order
(`order by md5(restatement_sk) limit 20`) and each one's full report sequence was
pulled from `fct_financial_fact` and inspected against `dim_filing` for form type
and fiscal period. The question asked of each was not "is this row correct" but
"did the filer actually publish a different number for the same described fact,
and does calling it a restatement mean what a reader would assume".

| Verdict | Count |
|---|---|
| Genuine revision of the reported figure | 14 |
| Genuine change, but retroactive re-presentation rather than correction | 3 |
| Artefact, the underlying figure did not change | 3 |

**17 of 20 held up as real changes in what the filer published. 14 of 20 held up
as corrections** in the sense the word normally carries.

**The clean cases.** Several are textbook and need no interpretation. Nutex Health
restated FY2024 stockholders' equity from $146,344,749 to $132,437,993 in a 10-K/A
(−9.5%). Cellectar Biosciences restated FY2023 non-operating income from +$917,147
to −$3,869,967 in a 10-K/A, a sign reversal. Faraday Future restated Q1-2023
related-party notes from $8,643,000 to $9,201,000 in a 10-Q/A. Elvictor Group
revised Q2-2024 net income from $32,701 to $32,071, a digit transposition,
corrected in the next 10-Q.

**Three artefacts, and each represents a measurable class.**

*Exact scale changes.* BC Partners Lending reported an investment at fair value of
**4,064** in its Q1-2023 10-Q and **4,064,000** in every filing thereafter, the
same digits, a factor of exactly 1,000. The filer changed reporting scale; the
holding did not change value. Across the population, **11,846 restatements (2.78%)
have an exact power-of-ten ratio** between first and latest value. This is also
what puts the p99 of the "all" direction at exactly 999.0, a ×1000 scale change
expressed as a percentage.

| Scale factor | Restatements |
|---|---|
| ×1000 | 4,774 |
| ÷1000 | 3,587 |
| ÷10 | 1,349 |
| ÷100 | 1,260 |
| ×10 | 697 |
| ×100 | 179 |
| **Total** | **11,846 (2.78%)** |

*Precision re-reporting.* HPS Corporate Capital Solutions reported Q1 2024 trustee
fees of **$55,943**, then **$56,000** a year later, a 0.102% "revision" that clears
the 0.1% threshold by two thousandths of a percent. Barnes & Noble Education is the
same defect inverted: treasury shares of **27,000** in two 10-Qs, then **27,267** in
the 10-K. Checking that filer's other treasury-share reports settles it. Every one
is a round thousand (3,842,000; 1,948,000; 2,188,000; 2,426,000; 2,533,000), so
27,000 is a rounded report and 27,267 is the exact one. The underlying count did not
move. Across the population, of the 49,088 restatements below 1%, **4,420 have a
later value that is an exact multiple of 1,000 where the first value is not**,
against only **334 the other way round** a 13× asymmetry that is hard to explain
as anything but precision changes being read as revisions.

*Retroactive share splits.* Brain Scientific's diluted share count went from
29,520,454 to 347,333, a ratio of exactly 85.0. Luminar Technologies reported
291,942,087 common shares outstanding in eight consecutive filings, then 19,444,545
in the ninth: a ratio of 15.014, a 1-for-15 reverse split applied retroactively.
FangDD Network is the decisive case, because it happened to all three share classes
at once:

| Class | 2024-04-19 | 2025-04-23 | 2025-09-29 |
|---|---|---|---|
| A | 33,312,108,296 | 5,922,152 | 370,135 |
| B | 490,418,360 | 87,186 | 5,450 |
| C | 7,071,427 | 1,258 | 79 |

The ratios are identical across all three classes. 5,625 then 16, which no
error correction produces. These are two successive share consolidations.

Tested across the population: **47.05% of share-denominated restatements carry a
near-integer shrink ratio between 1.5 and 10,000, against 2.45% of USD-denominated
ones** a 19× enrichment over the base rate. Share counts are 11.87% of all
restatements with a median revision of 96%, and that median is a split artefact,
not a measure of error.

**A fourth class the sample missed, found by following the magnitude tail.**
Restatements denominated in Argentine pesos number 9,725 (2.28% of the total) with
a median revision of 211% and 80–91% upward. They are concentrated in five issuers:

| Company | Restatements | Median revision | % upward |
|---|---|---|---|
| GRUPO FINANCIERO GALICIA SA | 2,707 | 136.4% | 86.6 |
| GRUPO SUPERVIELLE S.A. | 1,248 | 211.4% | 79.6 |
| MACRO BANK INC. | 1,072 | 211.4% | 90.9 |
| GAS TRANSPORTER OF THE SOUTH INC | 714 | 211.4% | 81.9 |
| TELECOM ARGENTINA SA | 687 | 211.4% | 71.9 |

Four of the five share a median of **exactly 211.4%**, which is the signature of a
common index rather than of independent errors. This is **IAS 29 hyperinflation
accounting**: Argentine issuers are required to restate prior-period figures into
current purchasing power every reporting period. It is mandatory re-presentation,
the opposite of a control failure, and it explains why Grupo Financiero Galicia
tops the §2.5 chain concentration with 979 long chains.

**Four checks run across the whole population, not sampled.** Everything above was
found by sampling and then measured. These four were defined first and counted
directly, so they carry no sampling error: each is a closed predicate over
`int_restatements`, and the first three are **mutually disjoint**, no restatement
is counted twice.

| Category | Predicate | Restatements | % of 426,706 |
|---|---|---|---|
| Zero-origin | `first_reported_value = 0` | 6,950 | 1.63 |
| Extreme magnitude | `abs(pct_revision) > 100` (>10,000%) | 10,061 | 2.36 |
| Sign flip | `first_reported_value = -latest_reported_value` | 29,118 | 6.82 |
| **Union (disjoint)** | | **46,129** | **10.81** |

**Roughly one restatement in nine is identifiable from the values alone as a
reclassification, a rescaling or a sign correction rather than a revision of a
value.** The fourth check is not a class of rows but a test of the §2.2 direction
result against the other three.

*Zero-origin (6,950).* A fact first published as zero and later at a non-zero
value. There is no denominator, so these carry no `pct_revision` and sit outside
every magnitude statistic. The dominant mechanism is **reclassification into a
line that previously did not exist**, and discontinued operations is the clearest
case: 860 of the 6,950 carry a tag naming discontinued operations.

General Electric is the worked example, because the arithmetic closes. Financing
cash flow from discontinued operations for FY2022:

| Filed | Form | Discontinued ops | Continuing ops | Total financing |
|---|---|---|---|---|
| 2023-02-10 | 10-K | 0 | −5,585,000,000 | −5,585,000,000 |
| 2023-04-25 | 8-K | 8,102,000,000 | −13,688,000,000 | −5,585,000,000 |
| 2024-02-02 | 10-K | 8,102,000,000 | −13,688,000,000 | −5,585,000,000 |
| 2025-02-03 | 10-K | 7,955,000,000 | −13,540,000,000 | −5,585,000,000 |

**The total never moves.** GE spun off GE HealthCare in January 2023 and recast
FY2022 into discontinued-operations presentation in the 8-K that April. The
discontinued line moves from 0 to +8,102,000,000 and the continuing line moves by
−8,103,000,000 offsetting to within one million dollars of GE's own rounding.
Not one figure about 2022 changed; the partition of an unchanged total between two
tags changed. Note also that this single event produces **two** rows in
`int_restatements`, one on each tag: a reclassification inflates the count by as
many tags as it touches.

The class is not uniformly artefactual, and the honest reading is narrower than
"all reclassification". Merck's FY2023 acquired-IPR&D write-off is reported as 0
in the FY2023 10-K and $11,409,000,000 in the FY2024 10-K; nothing here shows
whether that is a repartition like GE's or a figure the first filing simply did not
break out, and *no offsetting counterpart was sought for it*. What the whole class
does share is that **none of these is a filer changing its mind about a number's
magnitude**, which is what "restatement" implies to a reader. 6,233 of the 6,950 are USD, 446 share counts; the median arrives at 364
days, matching the population.

*Extreme magnitude (10,061).* Revisions exceeding 10,000% of the original. A
figure genuinely wrong by two orders of magnitude and surviving audit is rare; a
figure whose *scale, unit or share basis* changed is not. Three mechanisms account
for most of the bucket, and **5,358 of the 10,061 (53%) have an exact power-of-ten
ratio** between first and latest value, the single strongest signature that no
economic quantity moved.

Kamada Ltd is the cleanest rescaling. Between its 6-K of 2023-11-13 and its 6-K of
2024-11-13, **145 of 151 restatements are a factor of exactly 1,000, across 82
distinct tags** assets 337,056 → 337,056,000, additional paid-in capital
265,700 → 265,700,000. One filer changed its reporting scale from thousands to
units and contributed 145 rows to the population, none of them a changed fact.

Aditxt is the per-share mechanism, and it is self-proving because the denominator
is in the dataset too:

| Filed | Form | Diluted EPS | Weighted average diluted shares |
|---|---|---|---|
| 2024-05-20 | 10-Q | −9.21 | 1,610,872 |
| 2025-05-15 | 10-Q | −91,439.43 | 161 |

The share count shrinks by 10,005× and the loss per share grows by 9,928× the
same ratio to within 0.8%, which is the rounding of a two-decimal EPS. This is a
reverse split applied retroactively to Q1-2024 comparatives. It registers as a
992,700% "restatement" of EPS. **This extends the split finding above**, which
measured splits only on share-count units: the same event re-presents every
per-share figure as well, and 1,176 of the extreme bucket are per-share tags
against 2,938 share counts.

The third mechanism is reclassification off a near-zero base, AIG reported FY2022
income from discontinued operations as −$1,000,000 in the 10-Ks of 2023 and 2024,
then $8,383,000,000 in the 10-K of 2025-02-13, on deconsolidating Corebridge. The
value moved by 838,400% because the base was a rounding artefact, not because the
figure was wrong by that much. Percentage revision is not a meaningful statistic
when the denominator is one rounding unit, and 2,396 of the extreme bucket are
decreases against 7,665 increases the asymmetry a near-zero base produces.

*Sign flips (29,118).* `first_reported_value = -latest_reported_value` exactly:
the magnitude is **bit-identical** and only the sign changed. This is the most
mechanical category in the report, it is not an approximation or a threshold, it
is an equality, and at 6.82% it is the largest of the three.

| Company | Tag | Period | First | Latest |
|---|---|---|---|---|
| Crown Castle Inc. | `InterestExpenseDebt` | FY2023 | 850,000,000 | −850,000,000 |
| Edgewell Personal Care | `NetCashProvidedByUsedInOperatingActivities` | FY2024 | 231,000,000 | −231,000,000 |
| Johnson & Johnson | `OtherComprehensiveIncomeLossForeignCurrencyTranslationAdjustmentTax` | Q3-2024 | −51,000,000 | 51,000,000 |
| Boston Properties | `RepaymentsOfOtherDebt` | Q2-2023 | −730,000,000 | 730,000,000 |

Crown Castle reported $850m of interest expense in its FY2023 10-K and −$850m for
the same period in its FY2024 10-K. Interest expense did not become interest
income. The **element's sign convention** changed, whether an expense is tagged
positive as a cost or negative as a deduction. XBRL permits both, and
`negatedLabel` presentation reverses the displayed sign, so the rendered statement
can look identical either way while the tagged value flips.

The tag distribution confirms it: the concentration is in exactly the concepts
whose sign convention is contested, `IncomeTaxExpenseBenefit` (763, expense or
benefit), `IncreaseDecreaseInAccountsReceivable` (308) and
`IncreaseDecreaseInInventories` (284, working-capital movements presented as the
change or as its cash effect), `StockRepurchasedAndRetiredDuringPeriodValue`
(279). And **29,045 of the 29,118 have exactly two distinct values** a single
flip and no further movement, which is what a one-time convention change looks
like and not what an error under correction looks like.

Not every flip is a convention change, and the sample says so. Edgewell's operating
cash flow is in the table above, and the sign of operating cash flow is *not* a
contested convention, so that row is either a tagging error or a genuine sign
correction, and the values cannot say which. The claim the category supports is
narrower than "all 29,118 are conventions": it is that **in none of them did the
reported magnitude change**, so none of them is a revision of a value, whatever
else it is.

*Direction, tested against the other three (the fourth check).* §2.2 reports
57.76% of revisions as reductions. A sign flip has an identical magnitude, so
calling it an "increase" or a "decrease" is meaningless, `revision_direction`
reads the sign of `absolute_revision`, which for a flip is entirely an artefact of
the convention that changed. If the downward skew were manufactured by these
categories, removing them would collapse it.

| Population | Restatements | % downward |
|---|---|---|
| All | 426,706 | 57.76 |
| Excluding sign flips | 397,588 | **58.51** |
| Excluding all three categories | 380,577 | **60.02** |
| Sign flips alone | 29,118 | 47.54 |
| Zero-origin alone | 6,950 | 25.94 |
| Extreme magnitude alone | 10,061 | 23.81 |

**The skew is robust, and the artefacts were working against it.** Sign flips are
near-balanced at 47.54% downward, which is what a convention change should look
like, it has no reason to prefer a direction. Zero-origin and extreme-magnitude
restatements are strongly *upward* (74% and 76%), because both are dominated by
values rising off a zero or near-zero base. Removing all three therefore **raises**
the downward share from 57.76% to 60.02%. The direction finding does not depend on
the contaminated rows; it is diluted by them.

*Root cause: established for sign flips and rescalings, hypothesised for
zero-origin.* Bit-identical magnitudes and exact power-of-ten ratios are
signatures no error process produces, and the Aditxt and GE cases are confirmed by
an independent series in the same dataset. The zero-origin attribution to
reclassification rests on the GE arithmetic and the discontinued-operations tag
concentration, which is strong but is one worked case, not a population test.

**Aggregate effect on the headline.** Seven classes are now quantified, from two
methods, three found by sampling and then measured, three defined first and
counted directly, plus the split class. They overlap, so they cannot be added.
Measured against each other:

| Class | Found by | Restatements | Overlap with the four-category tests |
|---|---|---|---|
| Sign flips | direct count | 29,118 | (disjoint) |
| Extreme magnitude (>10,000%) | direct count | 10,061 | (disjoint) |
| Zero-origin | direct count | 6,950 | (disjoint) |
| Power-of-ten scale changes | sampling | 11,846 | 4,778 sit inside the extreme bucket |
| IAS 29 re-presentation (ARS) | sampling | 9,725 | 40 |
| Sub-1% precision re-reports | sampling | ~4,420 | none |
| **Union of the above** | | **~69,500** | **16.3% of the population** |

The union is approximate in its last figure and the reason is stated rather than
smoothed over: reproducing the scale-change predicate at the tolerance used for the
direct counts returns 14,044 rather than the 11,846 tabulated above, so the union
sits between roughly 67,000 and 69,500. **Call it 16% of the population, give or
take half a point.**

Retroactive share splits (23,839) are disjoint from all three directly counted
categories, a split on a share *count* is a shrink of less than 100%, so it can
never enter the extreme bucket, and they stay out of the union because they are
genuine changes to a published figure rather than artefacts. Their per share
counterparts are a different matter: the Aditxt case shows the same split event
re-presenting EPS as a five figure percentage, and those 1,176 per-share rows *are*
inside the extreme bucket.

**Removing the artefact union moves the headline rate from 4.785% to
approximately 4.01%.** That is the ceiling on the false positive correction, and it
is materially larger than the 6.1% this section reached from sampling alone. The
direct counts found more than the sample did, which is the expected direction and
the reason they were run.

**The headline finding survives verification.** The rate is not over flagged by
anything like §1.9's 60× a 16% correction leaves a restatement rate near 4%,
still low single digits, still the shape the design predicted. Two results survive
in different ways. The **direction** result strengthens: the artefact classes were
diluting the downward skew rather than creating it, and removing all three raises
reductions from 57.76% to 60.02%. The **magnitude** distribution in §2.2 does not
survive unqualified, the mass above 90% is substantially re-presentation rather
than correction, and §2.2 is written accordingly.

**What verification did not cover.** Nothing was checked against the original
filings on EDGAR; all inspection was against the loaded data, so a sequence that is
internally coherent may still misrepresent what the filer submitted. Twenty is a
small sample against 426,706 and supports classification of failure *modes*, not a
precise false-positive rate, the population-level tests above are what carry the
percentages. No attempt was made to distinguish a correction from a
reclassification where the values give no signature, which §2.8 records as a
structural limit rather than a sampling one.

---

### 2.8 Limitations

**The rounding threshold is a judgement call.** 0.001 was chosen to match §1.10's
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

**Restatement detection cannot distinguish a correction from a reclassification or
a taxonomy change.** This is the structural limit of the method and it is not
fixable by tuning. `int_restatements` observes that a filer published a different
number for the same described fact; it cannot observe *why*. Four distinct events
are indistinguishable in the values alone:

- a genuine error correction
- a reclassification between line items, where a figure moves from one tag to
  another and both change without anything economic having happened
- a retroactive re-presentation reverse splits (§2.7), IAS 29 hyperinflation
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

**Twelve quarters is a short window and it biases the rate downward.** The loaded
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

**The 4.785% headline is therefore a lower bound.** The best-observed cohort
restates at 5.35%, and even that is censored, since a 2023 figure can still be
revised in 2026. Loading the SEC's full history from 2009 Q2 would raise the rate;
this analysis cannot say by how much.

Left-censoring bites at the other end and is why §2.4 discards its first four
quarters: a revision published in 2023 Q1 has no original in the window to be a
revision *of*.

**Further limits, stated briefly.**

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
