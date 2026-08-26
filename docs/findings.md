# Findings

## §1 — Data quality of SEC XBRL filings

> Stage 1 deliverable. Write this up as you build. Each subsection:
> **question → what the query does → the number → what it means.**
>
> Numbers go in as measured. If a rule has false positives, say so here rather
> than quietly tuning the threshold until it looks clean.

**Scope:** SEC Financial Statement Data Sets, quarters `____` to `____`.
`____` filings, `____` numeric facts.

### 1.1 Scorecard

_Paste the output of `dq_scorecard` here._

| Rule | Dimension | Severity | Rows affected | % |
|---|---|---|---|---|
| | | | | |

### 1.2 How long until a number is knowable?

_From `dq_filing_lag_profile`. Median and p90 lag by form type. The finding is
the size of the window during which anyone acting on "current" fundamentals is
acting on data that has not been published._

### 1.3 Comparability: custom tag sprawl

_From `dq_custom_tag_share`. Does custom tag usage vary by filer status? If
smaller filers use more company-specific extensions, their numbers are harder to
compare against peers — a real problem in fundamental analysis._

### 1.4 Unit of measure inconsistency

_From `dq_unit_inconsistency`. How many tags appear under more than one unit?
Distinguish legitimate cases (a count and a dollar value sharing a tag) from
genuine tagging errors._

### 1.5 Sign convention violations

_To build: join `stg_numeric` to `stg_tags` on `natural_balance` and count facts
reported with the wrong sign for their credit/debit nature._

### 1.6 Coverage gaps

_To build: companies with a missing quarter inside an otherwise continuous
filing series. Gap-and-island over the filing sequence._

---

## §2 — Restatements (Stage 2)

## §3 — Filing behaviour and comparables (Stage 3)
