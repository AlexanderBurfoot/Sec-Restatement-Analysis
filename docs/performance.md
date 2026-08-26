# Performance case study

> Stage 3 deliverable. Three cases, each documented as:
> query → plan before → change and why → plan after → wall clock.
>
> Capture baselines **before** creating any index, and `ANALYZE` before every
> plan capture or the numbers are noise.

## Case 1 — Composite index for the restatement self-join

## Case 2 — BRIN on filed_date

BRIN stores per-block-range summaries rather than per-row entries, so on an
append-only, naturally time-ordered table it is a fraction of a B-tree's size at
comparable selectivity. **Record both index sizes** — the ratio is half the point.

## Case 3 — Correlated subquery rewritten as a window function

## Summary

| Case | Before | After | Speedup | Change |
|---|---|---|---|---|
| 1 | | | | composite B-tree |
| 2 | | | | BRIN |
| 3 | | | | window function rewrite |
