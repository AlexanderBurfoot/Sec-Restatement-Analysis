# Query performance

**Report date:** 2026-08-31
**Scope:** three query optimisations measured against `public_marts.fct_financial_fact`
**Table under test:** 42,797,341 rows · 14 GB heap · 1,835,626 blocks
**Author:** Alexander Burfoot

Three cases, each measured before and after a single change. Case 1 adds a
composite B-tree, Case 2 adds a BRIN, Case 3 changes no schema at all and
rewrites a correlated subquery as a window function.

One of the three did not work. Case 2 is reported at the length it is *because*
it failed, and the reason it failed is the most transferable thing here.

A fourth thing happened that was not planned: the measurement environment
degraded by ~45% mid-session, which invalidated a first round of numbers. Every
figure below comes from a single clean pass taken after that was diagnosed and
cleared. [Measurement drift](#measurement-drift) documents it, because a
performance document that hides its own instrumentation problem is not worth
much.

---

## Hardware and configuration

Timings without an environment are not results, so:

| | |
|---|---|
| Host | Apple M4 Pro, 12 cores, 24 GB RAM, macOS 15.5 (24F74) |
| Container runtime | Docker Desktop 29.3.0, `linux/arm64` |
| Docker VM | 12 CPUs, **7.65 GB RAM** |
| Postgres | 16.15, `aarch64-unknown-linux-gnu` (Debian) |
| Storage | Docker managed volume `pgdata` on the VM's virtual disk |

Server settings, all from `docker-compose.yml` and unchanged throughout:

```
shared_buffers                  1GB
work_mem                        64MB
maintenance_work_mem            512MB
effective_cache_size            3GB
max_parallel_workers_per_gather 4
random_page_cost                1.1
track_io_timing                 on
```

**The most important number above is 7.65 GB.** The heap is 14 GB. It does not
fit in the VM's page cache, let alone in `shared_buffers`. Every sequential scan
in this document therefore re-reads most of the table from the virtual disk on
every execution, and no amount of repetition makes a full scan fast. The
converse also matters: an index whose working set *is* a gigabyte or two caches
completely after one execution, which is why the after-timings in Cases 1 and 2
show a large first-run penalty and then flatten. Both are reported; neither
alone is honest.

`fct_financial_fact` carries one pre-existing index, a 2410 MB B-tree on
`financial_fact_sk` declared in the model config. It is present in every
measurement including the baselines, and no query here can use it.

---

## Method

- `ANALYZE public_marts.fct_financial_fact` before every plan capture.
- **All three baselines were captured before any index was created.**
- Every index created here was dropped before the next case began, and the
  closing state of the table is identical to the opening state: one index, on
  `financial_fact_sk`. Verified after the final drop.
- Wall clock is psql's `\timing`, server round-trip, excluding `docker exec`
  startup. Three runs minimum, reported as a range with the median called out.
  First run is reported separately wherever it differs materially.
- `EXPLAIN (ANALYZE, BUFFERS)` is a separate execution from the timed runs, so
  its `Execution Time` differs slightly from the corresponding wall clock. The
  two are never mixed inside one comparison.
- Case 2's before/after were additionally interleaved (baseline → BRIN →
  baseline → B-tree → baseline) so a monotonic trend could not be mistaken for
  an effect.
- Case 3's two forms were checked for equivalence by `md5(string_agg(...))` over
  the full ordered result, not by comparing row counts.
- Where wall clock and block counts disagree about whether something helped, the
  block counts win. They were identical across all three environment regimes;
  the wall clocks were not.

---

## Summary

| # | Query | Before | After | Change | Result |
|---|---|---|---|---|---|
| 1 | Restatement self-join, 20 filers | 57.0 s | **2.31 s** | B-tree `(cik, tag, period_end_date)`, 1027 MB | **25×** steady state, 4.1× first run |
| 2 | One month of facts by `filed_date` | 8.0 s | 6.4 s | BRIN on `filed_date`, 376 kB | **no change, identical plan** |
| 2b | *same query* | 8.0 s | **1.01 s** | B-tree on `filed_date`, 283 MB | **8×**, at 771× the index size |
| 3 | First/latest value per described fact | 30.0 s | **10.6 s** | correlated subquery → window function | **2.8×** end to end; ~1,950× on the step replaced |
| 3b | *same, 3.6× the rows* | 192.2 s | **10.3 s** | *same* | **18.6×** |

Cases 1, 3 and 3b are genuine. Case 2's BRIN is a genuine negative result. Case
2b is the control proving the query *was* improvable and that BRIN specifically
was the wrong instrument.

Three of these are smaller than the numbers a first pass produced, and the
differences are explained rather than dropped: Case 1 measured 41× and Case 2b
11× before the environment was stabilised. The figures above are the defensible
ones.

---

## Case 1, composite B-tree for the restatement self-join

### The query

Comparing a described fact across filings is the whole mechanism of Stage 2.
`int_restatements` does it with a window function over one sort, but the
drill-down form, *show me the revision pairs for these specific filers*, is a
self-join, and it is the shape a person writes interactively:

```sql
select
    original.cik,
    count(*)                                        as revision_pairs,
    count(distinct original.tag)                    as tags_revised,
    max(abs(revision.value - original.value))       as largest_absolute_revision
from public_marts.fct_financial_fact as original
join public_marts.fct_financial_fact as revision
  on  revision.cik             = original.cik
  and revision.tag             = original.tag
  and revision.period_end_date = original.period_end_date
  and revision.qtrs            = original.qtrs
  and revision.unit_of_measure = original.unit_of_measure
  and revision.segments        = original.segments
  and revision.coregistrant    = original.coregistrant
  and revision.filed_date      > original.filed_date
  and revision.value          is distinct from original.value
where original.cik in (1114700, 1517399, 1345126, 715957, 1347426, 1071321,
                       5272, 929351, 40545, 874501, 1615063, 1915657, 1415311,
                       1556593, 931427, 1503274, 1005286, 932470, 907471, 933267)
group by original.cik
order by revision_pairs desc;
```

The 20 CIKs are the top filers by `total_restatements` in
`rst_serial_restaters`. They select **255,605 rows, 0.60% of the table**, the
driving side is highly selective, which is exactly the condition under which an
index should win.

The join is on the seven-column natural key minus `adsh`, matching
`int_restatements`. `segments` and `coregistrant` are never null in this table
(verified: zero nulls in both), so plain equality is correct and `is distinct
from` is not needed on them.

### Before

```
Sort  (cost=6264850.00..6264868.80 rows=7518 width=56) (actual time=56095.564..56095.657 rows=20 loops=1)
  Buffers: shared hit=7556357 read=3457475, temp read=628398 written=655078
  I/O Timings: shared read=66881.579, temp read=4701.714 write=1406.881
  ->  GroupAggregate  (cost=6045710.61..6264365.99 rows=7518 width=56) (actual time=50100.334..56095.627 rows=20 loops=1)
        Group Key: original.cik
        ->  Gather Merge  (cost=6045710.61..6264090.24 rows=13371 width=57) (actual time=49959.322..56088.013 rows=58089 loops=1)
              Workers Planned: 4
              Workers Launched: 4
              ->  Merge Join  (cost=6044710.55..6261497.57 rows=3343 width=57) (actual time=49854.752..53409.716 rows=11618 loops=5)
                    Merge Cond: ((revision.cik = original.cik) AND (revision.tag = original.tag) AND (revision.period_end_date = original.period_end_date) AND (revision.qtrs = original.qtrs) AND (revision.unit_of_measure = original.unit_of_measure) AND (revision.segments = original.segments) AND (revision.coregistrant = original.coregistrant))
                    Join Filter: ((revision.filed_date > original.filed_date) AND (revision.value IS DISTINCT FROM original.value))
                    Rows Removed by Join Filter: 129786
                    ->  Sort  (cost=3555832.73..3582579.26 rows=10698610 width=108) (actual time=22987.802..26051.123 rows=8032114 loops=5)
                          Sort Key: revision.cik, revision.tag, revision.period_end_date, revision.qtrs, revision.unit_of_measure, revision.segments, revision.coregistrant
                          Sort Method: external merge  Disk: 1042312kB
                          Worker 0:  Sort Method: external merge  Disk: 1042888kB
                          Worker 1:  Sort Method: external merge  Disk: 1047248kB
                          Worker 2:  Sort Method: external merge  Disk: 1043688kB
                          Worker 3:  Sort Method: external merge  Disk: 1063592kB
                          ->  Parallel Seq Scan on fct_financial_fact revision  (cost=0.00..1942612.10 rows=10698610 width=108) (actual time=415.795..10973.698 rows=8559468 loops=5)
                    ->  Sort  (cost=2488877.82..2489210.75 rows=133175 width=108) (actual time=26855.987..26871.122 rows=303638 loops=5)
                          Sort Key: original.cik, original.tag, original.period_end_date, original.qtrs, original.unit_of_measure, original.segments, original.coregistrant
                          Sort Method: quicksort  Memory: 44474kB
                          ->  Seq Scan on fct_financial_fact original  (cost=0.05..2477542.65 rows=133175 width=108) (actual time=138.929..26379.309 rows=255605 loops=5)
                                Filter: (cik = ANY ('{1114700,...}'::bigint[]))
                                Rows Removed by Filter: 42541736
Execution Time: 56137.102 ms
```

**What the planner was doing, and why.** With no index on any join or filter
column, `cik = ANY(...)` has no access path. The only way to find 255,605 rows
is to look at all 42,797,341 and discard 42,541,736, the `Rows Removed by
Filter` line says so directly.

Having decided to scan, the planner then had to join. A hash join would need a
hash table over the unrestricted `revision` side, 42.8M rows keyed on seven
columns including `segments`, a text column that runs to 491 characters, with
`work_mem` at 64 MB. It costed that as worse than a merge join, and it was
right. So it chose a merge join, which requires **both** inputs sorted on all
seven join columns. The small side sorts in memory at 44 MB. The large side
cannot: it spills as an external merge, **1,042–1,064 MB per parallel
participant, 5.0 GB in total**, corroborated by `temp written=655078` blocks.

The plan reads 3,457,475 blocks, writes 5 GB of temporary files, reads them
back, and spends 66.9 s of measured shared I/O plus 6.1 s of temp I/O, to
return twenty rows.

Note the estimates too: 3,343 rows against 11,618 actual on the join, 7,518
groups against 20 actual. Poor selectivity estimation is a consequence of having
no statistics-bearing index on the correlated columns, and it feeds back into
the plan choice.

### The change

```sql
create index perf_fct_cik_tag_period
    on public_marts.fct_financial_fact (cik, tag, period_end_date);
```

Column order is the point, and it is not arbitrary:

- **`cik` leads** because it is the only column the query itself constrains
  (`cik in (...)`). A leading column the query cannot constrain would make the
  index unusable for the driving scan.
- **`tag` second, `period_end_date` third** because on the inner side of the
  join all three arrive as equalities from the outer row, so all three are
  usable as an index condition. `cik` alone would locate 255,605 rows per outer
  row; all three narrow it to a handful.
- The remaining four key columns (`qtrs`, `unit_of_measure`, `segments`,
  `coregistrant`) are deliberately **excluded**. `segments` is wide text and
  would inflate the index badly for little further selectivity. They are cheap
  to recheck as a filter once the index has cut the candidate set, which is what
  the plan below shows it doing.

Cost: **1027 MB**, about 30 s to build and analyse.

### After

```
Sort  (cost=239173.24..239191.88 rows=7459 width=56) (actual time=2402.995..2421.504 rows=20 loops=1)
  Buffers: shared hit=13319563 read=158717
  I/O Timings: shared read=902.352
  ->  GroupAggregate  (cost=236790.10..238693.45 rows=7459 width=56) (actual time=2384.373..2421.493 rows=20 loops=1)
        ->  Gather Merge  (cost=236790.10..238415.26 rows=13573 width=57) (actual time=2383.475..2411.336 rows=58089 loops=1)
              Workers Planned: 4
              Workers Launched: 4
              ->  Sort  (cost=235790.05..235798.53 rows=3393 width=57) (actual time=2371.588..2372.405 rows=11618 loops=5)
                    Sort Method: quicksort  Memory: 1385kB
                    ->  Nested Loop  (cost=1559.99..235591.07 rows=3393 width=57) (actual time=45.043..2364.003 rows=11618 loops=5)
                          ->  Parallel Bitmap Heap Scan on fct_financial_fact original  (cost=1559.43..144110.81 rows=34326 width=108) (actual time=31.271..161.608 rows=51121 loops=5)
                                Recheck Cond: (cik = ANY ('{1114700,...}'::bigint[]))
                                Heap Blocks: exact=32847
                                Buffers: shared hit=138249 read=23184
                                ->  Bitmap Index Scan on perf_fct_cik_tag_period  (cost=0.00..1525.05 rows=137305 width=0) (actual time=25.369..25.369 rows=255605 loops=1)
                                      Index Cond: (cik = ANY ('{1114700,...}'::bigint[]))
                                      Buffers: shared hit=539 read=80
                          ->  Index Scan using perf_fct_cik_tag_period on fct_financial_fact revision  (cost=0.56..2.66 rows=1 width=108) (actual time=0.039..0.042 rows=0 loops=255605)
                                Index Cond: ((cik = original.cik) AND (tag = original.tag) AND (period_end_date = original.period_end_date))
                                Filter: ((filed_date > original.filed_date) AND (value IS DISTINCT FROM original.value) AND (qtrs = original.qtrs) AND (unit_of_measure = original.unit_of_measure) AND (segments = original.segments) AND (coregistrant = original.coregistrant))
                                Rows Removed by Filter: 61
                                Buffers: shared hit=13181250 read=135533
Execution Time: 2429.464 ms
```

**Why it changed.** Two independent things happened, and only the first is
usually named:

1. The **driving scan** became a bitmap index scan. 619 index buffers locate all
   255,605 qualifying rows; the heap is then visited in physical order for
   32,847 blocks instead of 1,835,626.
2. The **join strategy** changed from merge to nested loop, and this is where
   most of the time went. A nested loop is only viable when the inner side has a
   cheap random access path. Once it has one, neither input needs sorting,
   which deletes the 5 GB external merge outright. `temp` disappears from the
   `Buffers` line entirely.

The `Index Cond` uses all three index columns, and `Rows Removed by Filter: 61`
shows the recheck doing exactly the small amount of work it was designed for:
the index narrows each outer row to ~61 candidates, and the four unindexed key
columns discard them cheaply.

There is a real cost on the other side of the ledger, visible in the same plan.
`shared hit` went *up*, from 7.56M to 13.32M, because the nested loop performs
255,605 separate index descents. The trade is 5.8M extra cached buffer touches
in exchange for 3.3M fewer disk reads and 5 GB of eliminated temp I/O. On this
hardware that trade is worth about 25×; on a machine where the whole table
cached, it would be worth much less.

### Timings

| | Before | After |
|---|---|---|
| Run 1 (cold page cache) | 55.723 s | **13.850 s** |
| Subsequent runs | 56.969 s, 57.759 s | 2.907, 2.938, 2.428 s |
| Steady state (runs 5–10) | n/a | 2.343, 2.306, 2.288, 2.305, 2.324, 2.305 s |
| **Median** | **57.0 s** | **2.31 s** |
| `EXPLAIN ANALYZE` execution | 56.137 s | 2.429 s |
| Planner cost estimate | 6,264,850 | 239,173 (26× lower) |
| Blocks read | 3,457,475 | 158,717 (21.8× fewer) |
| Temp written | 655,078 blocks (5.0 GB) | none |
| Shared I/O time | 66.9 s | 0.90 s |

**25× at steady state, 4.1× on the first run.** Both are real and they measure
different situations. The first-run figure is what a person gets immediately
after a `dbt build` has churned the page cache; the steady-state figure is what
they get on the second and every later execution of an interactive session. The
baseline has no equivalent spread, 55.7 s to 57.8 s across every run, cold or
warm, because a 14 GB scan plus a 5 GB spill cannot be cached in a 7.65 GB VM.

A control from an earlier round, worth recording: restarting the Postgres
container to flush `shared_buffers` and re-running gave **1.484 s**, not the
first-run figure. The first-run penalty is cold *VM page cache* immediately
after `CREATE INDEX`, not cold `shared_buffers`, the index path's working set
survives a Postgres restart because it lives in the VM's cache, not the
server's. The same control on the baseline gave 45.170 s, in line with its warm
runs, confirming the baseline is cache-insensitive.

---

## Case 2, BRIN on `filed_date`

### The premise, and why it is wrong

The project brief describes this table as *"append-only and naturally
time-ordered,"* which is BRIN's ideal case. The first half is true. **The second
half is not**, and one query settles it:

```sql
select attname, correlation
from pg_stats
where schemaname = 'public_marts' and tablename = 'fct_financial_fact';
```

| Column | Correlation |
|---|---|
| `tag` | **0.967** |
| `source_quarter` | 0.107 |
| `period_end_date` | 0.043 |
| **`filed_date`** | **0.029** |
| `cik` | −0.007 |

`filed_date` has a physical correlation of **0.029**, which is approximately
none. BRIN stores only the min and max of the indexed column per block range and
skips a range when the predicate falls outside it. That works if and only if
values are physically grouped, and here they are not.

The table is not time-ordered because of how it is built: `fct_financial_fact`
joins `stg_numeric` to submissions, and `stg_numeric` reads the SEC's quarterly
bulk files, which are ordered by accession number within each quarter, not by
filing date. **Appending in load order is not the same as appending in date
order.** The incidental 0.967 on `tag` is the ordering the build actually
produced.

This was checked before any index was created. The case was run anyway, because
a negative result that is measured is worth more than one that is predicted.

### The query

A month of filings aggregated by day, the filing-volume question
`fil_lag_trend` asks directly ([`findings.md`](findings.md) §3.2), and a plain
`filed_date` range scan:

```sql
select
    filed_date,
    count(*)                                as facts_filed,
    count(distinct adsh)                    as filings,
    count(*) filter (where value is null)   as values_unparsed
from public_marts.fct_financial_fact
where filed_date between date '2025-02-01' and date '2025-02-28'
group by filed_date
order by filed_date;
```

It matches 1,840,725 rows, **4.30% of the table**.

### Before

```
GroupAggregate  (cost=2038949.00..2269639.83 rows=746 width=28) (actual time=7460.195..7693.842 rows=19 loops=1)
  Group Key: filed_date
  Buffers: shared hit=778 read=1835108
  I/O Timings: shared read=33116.086
  ->  Gather Merge  (cost=2038949.00..2251851.20 rows=1778117 width=31) (actual time=7458.414..7617.319 rows=1840725 loops=1)
        Workers Planned: 4
        Workers Launched: 4
        ->  Sort  (cost=2037948.94..2039060.27 rows=444529 width=31) (actual time=7440.045..7459.694 rows=368145 loops=5)
              Sort Key: filed_date, adsh
              Sort Method: quicksort  Memory: 31451kB
              ->  Parallel Seq Scan on fct_financial_fact  (cost=0.00..1996247.86 rows=444529 width=31) (actual time=73.792..7218.658 rows=368145 loops=5)
                    Filter: ((filed_date >= '2025-02-01'::date) AND (filed_date <= '2025-02-28'::date))
                    Rows Removed by Filter: 8191323
Execution Time: 7700.534 ms
```

Full parallel sequential scan, **1,835,108 blocks read**, 40.96M rows discarded.

### The change

```sql
create index perf_fct_filed_brin
    on public_marts.fct_financial_fact using brin (filed_date);
```

**376 kB**, built in about 10 s.

### After

**The plan does not change.** It is still a `Parallel Seq Scan`, with the same
filter, and it reads 1,834,404 blocks against the baseline's 1,835,108, the
same table, to within the noise of concurrent activity. Diffing the two plans'
node structure returns no differences. The planner declines to use the BRIN, and
it is right to.

This is the cleanest possible statement of the result: **the BRIN's effect on
this query is not small. It is zero, and that is provable from the plan rather
than inferred from a stopwatch.** The wall clocks (6.36 s with the BRIN against a
baseline band of 6.56–10.15 s) would on their own suggest the BRIN made things
slightly *faster*, which it plainly cannot have done. That wobble is page-cache
state, and it is exactly the kind of artefact this document exists to not report
as a finding.

Forcing the issue with `set enable_seqscan = off` shows what the index is
actually capable of:

```
GroupAggregate  (cost=2038916.19..2264427.36 rows=746 width=28) (actual time=10193.743..10461.867 rows=19 loops=1)
  Buffers: shared hit=129 read=1721216 written=92
  ->  Parallel Bitmap Heap Scan on fct_financial_fact  (cost=944.16..1997222.54 rows=434548 width=31) (actual time=102.880..9831.165 rows=368145 loops=5)
        Recheck Cond: ((filed_date >= '2025-02-01'::date) AND (filed_date <= '2025-02-28'::date))
        Rows Removed by Index Recheck: 7826817
        Heap Blocks: lossy=342537
        ->  Bitmap Index Scan on perf_fct_filed_brin  (cost=0.00..509.61 rows=42840636 width=0) (actual time=37.025..37.025 rows=17212160 loops=1)
              Index Cond: ((filed_date >= '2025-02-01'::date) AND (filed_date <= '2025-02-28'::date))
              Buffers: shared hit=65
Execution Time: 10469.443 ms
```

The BRIN scan itself costs 65 buffers and 37 ms. The index is doing its own job
efficiently. It then hands back **17,212,160 candidate rows to find 1,840,725
real ones**, a 9.4× over-fetch, and the heap scan reads **1,721,216 blocks: 94%
of the table**. `Rows Removed by Index Recheck: 7,826,817` per participant is
39.1M rows rechecked across five, so ~96% of the table was examined row by row.

BRIN excluded roughly **6% of blocks**. Because the recheck is not free, forcing
BRIN is *slower than not having it*: 10.47 s against 7.70 s.

### Would a finer range help?

A fair objection: `pages_per_range` defaults to 128, and the facts of a single
filing *are* physically contiguous even if filings are not in date order. If
each range covered fewer blocks, its min/max might tighten enough to exclude.
Tested at 32, 8 and 2:

| `pages_per_range` | Index size | Median wall clock | Plan chosen |
|---|---|---|---|
| no index | none | baseline | Parallel Seq Scan |
| 128 (default) | 376 kB | 6.36 s | Parallel Seq Scan |
| 32 | 1472 kB | 11.72 s | Parallel Seq Scan |
| 8 | 5824 kB | 11.40 s | Parallel Seq Scan |
| 2 | 23 MB | 11.95 s | Parallel Seq Scan |

Confirmed by `EXPLAIN` at `pages_per_range = 8`: still a `Parallel Seq Scan`.
Shrinking the range grows the index 62-fold and changes no plan, because range
granularity is not the problem. Even a 2-block range spans multiple filings with
unrelated `filed_date` values, so its min/max still straddles the predicate.

*(The wall clocks in that table were taken during the degraded regime described
below and are not comparable to the rest of this section. The plan choice, which
is the actual finding, is regime-independent.)*

### The control: an equivalent B-tree

```sql
create index perf_fct_filed_btree
    on public_marts.fct_financial_fact (filed_date);
```

```
GroupAggregate  (cost=1444847.97..1693417.53 rows=746 width=28) (actual time=852.505..1094.831 rows=19 loops=1)
  Buffers: shared hit=64 read=340457
  I/O Timings: shared read=708.659
  ->  Gather Merge  (cost=1444847.97..1674250.80 rows=1915927 width=31) (actual time=850.695..1018.830 rows=1840725 loops=1)
        Workers Planned: 4
        Workers Launched: 4
        ->  Sort  (cost=1443847.91..1445045.37 rows=478982 width=31) (actual time=814.475..834.106 rows=368145 loops=5)
              Sort Method: quicksort  Memory: 32173kB
              ->  Parallel Bitmap Heap Scan on fct_financial_fact  (cost=21423.99..1398656.89 rows=478982 width=31) (actual time=176.767..590.954 rows=368145 loops=5)
                    Recheck Cond: ((filed_date >= '2025-02-01'::date) AND (filed_date <= '2025-02-28'::date))
                    Heap Blocks: exact=65531
                    Buffers: shared read=340457
                    ->  Bitmap Index Scan on perf_fct_filed_btree  (cost=0.00..20945.01 rows=1915927 width=0) (actual time=71.381..71.381 rows=1840725 loops=1)
                          Index Cond: ((filed_date >= '2025-02-01'::date) AND (filed_date <= '2025-02-28'::date))
Execution Time: 1102.971 ms
```

The B-tree returns an **exact** bitmap, there is no `Rows Removed by Index
Recheck` line at all, and the heap scan reads **340,457 blocks against BRIN's
1,721,216**. That is 18.5% of the table, and it is the number that explains
everything above.

The February 2025 rows really are concentrated into about a fifth of the table's
blocks. The data has strong *local* clustering (one filing's facts sit together,
and a filing has exactly one `filed_date`) and no *global* monotonic ordering.
`pg_stats.correlation` measures the global property, and BRIN's min/max summary
can only exploit the global property. A B-tree bitmap exploits the local one,
because it collects exact TIDs first and only then sorts them into physical
order.

That 340,457 figure was identical in every environment regime measured, which is
why it, and not the seconds, is the transferable result.

### Index sizes and the ratio

| Index | Size | Blocks read by the test query | Median wall clock |
|---|---|---|---|
| BRIN on `filed_date` | **376 kB** | 1,721,216 (forced) | 6.36 s (plan unchanged) |
| B-tree on `filed_date` | **283 MB** | 340,457 | **1.01 s** |
| Ratio | **≈771×** | 5.1× fewer | ~8× faster |

BRIN is 771 times smaller. On this table that is 771 times smaller than
something that works, which is not a saving. The size ratio is the headline of
every BRIN write-up, including the one this case was designed to reproduce, and
in isolation it is meaningless: **BRIN's size advantage is only redeemable
against physical correlation, and correlation is a property of how the table was
written, not of what the column means.** `filed_date` is a monotonic real-world
quantity and the table is append-only, and neither fact was sufficient.

### Timings

| | Median | Runs |
|---|---|---|
| Baseline, no index (9 runs, interleaved) | **8.04 s** | 10.105, 8.044, 7.482 · 6.886, 6.557, 6.692 · 10.110, 10.151, 9.985 |
| BRIN, 376 kB | 6.36 s | 6.355, 6.499, 6.359 |
| BRIN forced with `enable_seqscan=off` | 10.47 s | not recorded |
| B-tree, 283 MB | **1.01 s** | 14.473 (first run), 1.006, 0.971, 1.017 |

The baseline's own spread is 6.56–10.15 s, a ±25% band, and it is not random
drift: the fast runs are the interleaved middle block and the slow ones bracket
the 283 MB index build that evicted the page cache. **The BRIN measurement sits
inside the baseline's own band**, which is why the plan comparison, not the
stopwatch, carries this case.

The B-tree's 8× is quoted against the baseline median. Against the baseline's
extremes it is 6.5× to 10×. The first-run 14.473 s is the cold-page-cache
penalty immediately after `CREATE INDEX`, the same artefact as in Case 1.

### What would make BRIN work

**Not established**, mechanism, not measurement. BRIN on `filed_date` needs the
heap physically grouped by `filed_date`. Two routes:

1. `CLUSTER` the table on a `filed_date` index. This rewrites 14 GB, takes an
   `ACCESS EXCLUSIVE` lock, and **is not maintained**: new incremental rows
   append unordered and correlation decays from the next `dbt build` onward.
2. Order the insert. `fct_financial_fact` is incremental with a 30-day
   `filed_date` lookback, so each run already writes a narrow band of filing
   dates; an `order by filed_date` in the model would make each batch internally
   ordered and the table approximately ordered overall.

Neither was done. Route 1 is not durable under this model's write pattern, and
route 2 changes a working model for the benefit of an index that is not needed:
the B-tree costs 283 MB and solves the problem today. Recording the mechanism is
the deliverable; changing the model is not.

---

## Case 3, correlated subquery rewritten as a window function

### The query, and where it comes from

This is the central computation of `int_restatements`: for each report of a
described fact, what was that fact *first* reported at, and what is it reported
at *now*. The model's own header comment records that an earlier formulation
"did not finish in fifty minutes", so the pathological form is not hypothetical
here. It is a shape this repository already had to abandon once.

Both forms build the same `reports` CTE, which collapses to one row per
described fact per publication date using the model's real tiebreak (highest
accession that day, then highest value):

```sql
with reports as (
    select
        cik, coregistrant, segments, tag, period_end_date, qtrs, unit_of_measure,
        filed_date,
        (array_agg(value order by adsh desc, value desc))[1] as reported_value
    from public_marts.fct_financial_fact
    where value is not null
      and cik = 1114700
    group by 1, 2, 3, 4, 5, 6, 7, 8
)
```

**Before**, the naive form, one correlated scalar subquery per output column:

```sql
select
    r.cik, r.tag, r.period_end_date, r.qtrs, r.unit_of_measure,
    r.filed_date, r.reported_value,
    (select r2.reported_value from reports as r2
      where r2.cik = r.cik and r2.coregistrant = r.coregistrant
        and r2.segments = r.segments and r2.tag = r.tag
        and r2.period_end_date = r.period_end_date and r2.qtrs = r.qtrs
        and r2.unit_of_measure = r.unit_of_measure
      order by r2.filed_date limit 1)        as first_reported_value,
    (select r2.reported_value from reports as r2
      where /* ... the same seven predicates ... */
      order by r2.filed_date desc limit 1)   as latest_reported_value
from reports as r;
```

**After**, the form `int_restatements` actually ships:

```sql
select
    cik, tag, period_end_date, qtrs, unit_of_measure,
    filed_date, reported_value,
    first_value(reported_value) over w      as first_reported_value,
    last_value(reported_value)  over w      as latest_reported_value
from reports
window w as (
    partition by cik, coregistrant, segments, tag, period_end_date, qtrs, unit_of_measure
    order by filed_date
    rows between unbounded preceding and unbounded following
);
```

The explicit frame is load-bearing. The default frame ends at the current row,
which would make `last_value` return the row it is called on.

### Scoping, stated plainly

The correlated form is quadratic and cannot be run at full scale. That is the
finding, not an obstacle to it. It is measured at two scopes so the scaling is
observed rather than asserted:

| Scope | Predicate | `reports` rows |
|---|---|---|
| A | `cik = 1114700` (the top serial restater) | 16,035 |
| B | 5 CIKs | 57,732 |

Both forms read the full 42.8M-row table to build `reports`; only the CTE is
scoped. Because `reports` is referenced three times in the correlated form,
Postgres materialises it, and the subqueries rescan the materialised CTE rather
than the base table.

### Equivalence

Checked, not assumed:

```sql
select md5(string_agg(row_to_json(t)::text, '|' order by row_to_json(t)::text)), count(*)
from ( <either form> ) t;
```

| Scope | Digest | Rows | Match |
|---|---|---|---|
| A | `8fc65d841bd40aaed3612404616d18a3` | 16,035 | **identical for both forms** |
| B | `f2679896ada4386a0eb1bbc8ed9e1f47` | 57,732 | **identical for both forms** |

### Before

```
CTE Scan on reports r  (cost=1971382.22..3705387.42 rows=4808 width=180) (actual time=10311.946..29928.255 rows=16035 loops=1)
  Buffers: shared hit=131089 read=1704873
  CTE reports
    ->  GroupAggregate  (cost=1970650.00..1971382.22 rows=4808 width=133) (actual time=10297.302..10307.762 rows=16035 loops=1)
          ->  Gather Merge ... Parallel Seq Scan on fct_financial_fact
                Filter: ((value IS NOT NULL) AND (cik = 1114700))
                Rows Removed by Filter: 8556119
  SubPlan 2
    ->  Limit  (cost=180.31..180.32 rows=1 width=36) (actual time=0.612..0.612 rows=1 loops=16035)
          ->  Sort  (cost=180.31..180.32 rows=1 width=36) (actual time=0.611..0.611 rows=1 loops=16035)
                Sort Key: r2.filed_date
                ->  CTE Scan on reports r2  (cost=0.00..180.30 rows=1 width=36) (actual time=0.304..0.611 rows=3 loops=16035)
                      Rows Removed by Filter: 16032
  SubPlan 3
    ->  Limit  (cost=180.31..180.32 rows=1 width=36) (actual time=0.612..0.612 rows=1 loops=16035)
          ->  Sort  (cost=180.31..180.32 rows=1 width=36) (actual time=0.612..0.612 rows=1 loops=16035)
                Sort Key: r2_1.filed_date DESC
                ->  CTE Scan on reports r2_1  (cost=0.00..180.30 rows=1 width=36) (actual time=0.305..0.611 rows=3 loops=16035)
                      Rows Removed by Filter: 16032
Execution Time: 29937.299 ms
```

`loops=16035` on both SubPlans, each scanning all 16,035 CTE rows and discarding
16,032. That is **2 × 16,035² = 514.2 million row comparisons** to produce
16,035 rows. Postgres cannot decorrelate a subquery with `ORDER BY ... LIMIT 1`,
so no better plan is available to it.

The CTE itself completes at 10,308 ms. Everything after that, **19.62 s**, is
the correlation.

### After

```
WindowAgg  (cost=1971724.34..1971904.64 rows=4808 width=197) (actual time=10088.320..10093.826 rows=16035 loops=1)
  Buffers: shared hit=131092 read=1704873
  ->  Sort  (cost=1971724.34..1971736.36 rows=4808 width=133) (actual time=10088.297..10088.761 rows=16035 loops=1)
        Sort Key: reports.cik, reports.coregistrant, reports.segments, reports.tag, reports.period_end_date, reports.qtrs, reports.unit_of_measure, reports.filed_date
        Sort Method: quicksort  Memory: 2660kB
        ->  Subquery Scan on reports  (cost=1970650.00..1971430.30 rows=4808 width=133) (actual time=10073.380..10083.765 rows=16035 loops=1)
              ->  GroupAggregate  (cost=1970650.00..1971382.22 rows=4808 width=133) (actual time=10073.379..10083.028 rows=16035 loops=1)
Execution Time: 10101.799 ms
```

One sort into partition order, one pass. `Sort Method: quicksort Memory: 2660kB`, so it fits in `work_mem` and never
touches disk. Sort plus `WindowAgg` together
span **10.1 ms**, against the correlated form's 19.62 s for the same answer.

### Why it changed

Both plans read the same 16,035 rows and answer the same question. The
difference is that the correlated form re-derives each group's ordering
independently for every row in that group, while the window function sorts once
and reads the first and last of each partition off an ordering it already has.

The `Buffers` lines make this unusually clean: **`read=1704873` in both plans,
identical to the block.** The correlated form performs *zero* extra I/O. Its
extra 19.62 s is pure CPU spent rescanning an in-memory CTE, the cost of asking
the same question 16,035 times instead of once.

### Timings

| | Scope A (16,035 rows) | Scope B (57,732 rows) |
|---|---|---|
| Correlated subquery | 29.328, 29.996, 30.175 s → **30.0 s** | 192.447, 191.932 s → **192.2 s** |
| Window function | 10.514, 10.597, 10.582 s → **10.6 s** | 10.498, 10.128 s → **10.3 s** |
| **End-to-end speedup** | **2.8×** | **18.6×** |
| Shared scan floor (the `reports` CTE) | 10.31 s | ~10.3 s |
| Time attributable to the rewritten step | 19.62 s → 10.1 ms | 181.9 s → ~10 ms |
| **Speedup on the step replaced** | **≈1,950×** | n/a |

**The 2.8× at scope A is the honest headline, and it is small.** Both forms pay
the same ~10.4 s to scan a 14 GB table that does not fit in the page cache, and
that floor is 35% of the correlated form's total. No rewrite can touch it; only
Case 1's kind of index could, and this query has no `cik`-indexed access path.

What the rewrite actually did is better read from the two scopes together.
Multiplying the input by 3.60× multiplied the correlated work by 9.3×
(19.62 s → 181.9 s), an observed exponent of **N^1.74**, near-quadratic, as the
`loops` count predicts. The window form did not move at all: 10.6 s → 10.3 s,
because its added work is one in-memory sort. The gap is 2.8× at 16k rows,
18.6× at 58k rows, and unbounded thereafter.

`int_restatements` runs this over the whole table, where `reports` is tens of
millions of rows rather than 16,035. Extrapolating N^1.74 from scope B to that
scale is why the model's header comment records fifty minutes without
completion. The window version builds in minutes.

One incidental result strengthens this. The 19.62 s figure was measured three
times under three different I/O regimes (see below), which changed the scan
floor from 7.5 s to 14.4 s. It came out at 19.6 s, 19.55 s and 19.62 s. The
correlated cost is CPU-bound on an in-memory structure and is the most
reproducible number in this document.

---

## Measurement drift

**Reported because it invalidated a full round of measurements, and because the
diagnosis is the reason the figures above can be trusted.**

Partway through the session, identical queries with identical plans became
progressively slower:

| Same query, same plan | Session start | Mid-session | Later | After VM restart |
|---|---|---|---|---|
| Case 2 baseline | 7.86–8.20 s | 11.30–11.76 s | 14.68–14.95 s | 6.56–10.15 s |
| Case 1 baseline | 40.90–41.68 s | 57.34–60.05 s | not measured | 55.72–57.76 s |

The host was never under obvious pressure (41% free memory, load average 4.5 on
12 cores). The degradation was confined to I/O: the Case 2 baseline's `shared
read` timing rose from 33.7 s to 68.6 s for *fewer* blocks read.

**Root cause: established as the Docker VM layer.** The evidence is the
recovery. Restarting the Postgres container alone gave only partial recovery
(11.34 s). Quitting Docker Desktop entirely and restarting the VM restored the
original regime (7.48 s). The mechanism *within* the VM, virtual-disk
behaviour after ~3 GB of index writes, host page-cache interaction, or something
else, is **not established** and was not tested further.

Two things did not move at all, in any regime:

- **Block counts.** The Case 2 B-tree read exactly 340,457 blocks in both
  regimes it was measured in. The forced BRIN removed exactly 7,826,817 rows by
  index recheck every time. Case 3's two forms read exactly the same number of
  blocks as each other in all three regimes.
- **CPU-bound work.** Case 3's correlated cost measured 19.6 s, 19.55 s and
  19.62 s while the scan floor beneath it nearly doubled.

Consequences, all handled:

1. **Every figure in this document comes from a single clean pass** taken after
   the VM restart, with the three cases measured back to back and the table
   returned to its baseline state between them. The pre-restart numbers appear
   only in this section, in the explicitly labelled Case 1 controls, and in the
   `pages_per_range` table, which is labelled where it sits.
2. Case 1's speedup fell from 41× to **25×**, and Case 2b's from 11× to **8×**,
   once measured in a stable regime with steady-state rather than
   best-observed after-timings. The larger numbers were not wrong so much as
   unreproducible, which for this purpose is the same thing.
3. Case 2's conclusion did not change at all, because it never rested on wall
   clock.

This is why the ratios here are quoted against a contemporaneous baseline, and
why plan structure and block counts are given more weight than seconds.

---

## Limitations

- **One machine, one storage stack, one afternoon.** Block counts, plan shapes
  and cost estimates transfer; the seconds do not.
- **The heap does not fit in RAM (14 GB against 7.65 GB).** This inflates every
  sequential-scan baseline and therefore every ratio quoted against one. On a
  host where the table cached fully, Case 1's baseline would be far faster and
  its 25× smaller. Case 3's ratios would *grow*, because its floor is scan-bound
  and its correlated cost is not.
- **`EXPLAIN ANALYZE` overhead is included in the plan captures.** Wall clock
  and plan timings are never mixed within a single comparison.
- **Case 3's scopes are small by necessity.** The correlated form cannot be run
  at the model's real scale, so the extrapolation to `int_restatements` rests on
  a two-point exponent fit, not on measurement.
- **Case 2's remedy is unverified.** The claim that ordering the incremental
  insert would make BRIN viable is mechanism, not result; no clustered
  measurement was taken.
- **No index created here was retained**, and no model was changed. This is a
  measurement exercise. `fct_financial_fact` ends it with the same single index
  on `financial_fact_sk` it began with, verified after the final drop. Whether
  the Case 1 index should be added to the model config is a separate decision
  that turns on write amplification during `dbt build`, which was not measured.
- **Case 1's query is a drill-down, not the model.** `int_restatements` does not
  execute this self-join; it uses the window-function form of Case 3. The index
  helps interactive investigation of specific filers, which is a real use, but
  it is not on the critical path of a `dbt build`.
