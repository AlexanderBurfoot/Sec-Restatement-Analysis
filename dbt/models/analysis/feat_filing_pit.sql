{{
    config(
        materialized='table',
        indexes=[{'columns': ['adsh'], 'type': 'btree'}]
    )
}}

/*
  Features for one filing using only what a reader had on its filing date.

  Two of the five features have a history, and this is the model that respects
  it. The company's prior restatement count admits a revision on the day that
  revision was published, not on the day the figure it corrected was filed. The
  sector base rate is an expanding window over filings whose own observation
  window had already closed, so it is a rate a reader could actually have
  computed, not one that borrows the answer from filings still being watched.

  Both are built the same way: the filings are unioned with their own events into
  one stream, sorted once, and read off a running sum. Query rows sort before
  same-day events, which is what makes the window strictly prior — a filing never
  sees a revision published on its own filing date, and never sees itself.

  A lateral as-of lookup per filing was the obvious alternative and was not
  written: 58,726 filings against a cumulative table of comparable size is a
  quadratic scan with no index to lean on inside a CTE, where this is one sort.
*/

{% set label_horizon_days = var('restatement_label_horizon_days') %}

{% set query_row = 0 %}
{% set event_row = 1 %}

with base as (

    select * from {{ ref('feat_filing_base') }}

),

sector_stream as (

    -- A filing appears twice: once on its filing date asking what the sector
    -- rate was, and once on the day its own label became final, contributing to
    -- the rate everyone after it reads.
    --
    -- The contribution is dated filed_date + horizon rather than filed_date
    -- because that is when the filing's outcome stopped being provisional.
    -- Counting a filing from its filing date would put filings still inside
    -- their observation window into the denominator as clean ones and bias
    -- every sector rate downward — the same censoring the horizon exists to
    -- remove, reintroduced through the feature.
    select
        sic_major_group_at_filing               as sic_major_group,
        filed_date                              as event_date,
        {{ query_row }}                         as event_order,
        adsh,
        null::int                               as is_resolved,
        null::int                               as is_restated
    from base

    union all

    select
        sic_major_group_at_filing,
        filed_date + {{ label_horizon_days }},
        {{ event_row }},
        null,
        1,
        case when was_restated then 1 else 0 end
    from base

),

sector_running as (

    -- Filings with no numeric SIC on the day share one null partition. The
    -- running sum accumulates over it like any other, but that total is
    -- discarded downstream rather than read as a sector: those filings count in
    -- the market stream and the final select routes them to it.
    select
        adsh,
        sum(is_resolved) over sector_history    as sector_prior_resolved,
        sum(is_restated) over sector_history    as sector_prior_restated,
        sum(is_resolved) over market_history    as market_prior_resolved,
        sum(is_restated) over market_history    as market_prior_restated
    from sector_stream
    window
        sector_history as (
            partition by sic_major_group
            order by event_date, event_order
            rows between unbounded preceding and current row
        ),
        market_history as (
            order by event_date, event_order
            rows between unbounded preceding and current row
        )

),

sector_rate as (

    select
        adsh,
        sector_prior_resolved,
        sector_prior_restated,
        market_prior_resolved,
        market_prior_restated
    from sector_running
    where adsh is not null

),

company_stream as (

    -- The same shape over the company rather than the sector. Here the event is
    -- dated the day the revision was published, with no horizon applied: a
    -- revision arriving on day 400 did not meet the label, but a reader on day
    -- 401 had seen it, and this feature is about what was known rather than
    -- about how the label was scored.
    select
        cik,
        filed_date                              as event_date,
        {{ query_row }}                         as event_order,
        adsh,
        null::int                               as is_revised_filing
    from base

    union all

    select
        cik,
        revision_first_seen_date,
        {{ event_row }},
        null,
        1
    from base
    where revision_first_seen_date is not null

),

company_running as (

    select
        adsh,
        sum(is_revised_filing) over company_history  as prior_restatement_count
    from company_stream
    window company_history as (
        partition by cik
        order by event_date, event_order
        rows between unbounded preceding and current row
    )

),

prior_restatements as (

    select
        adsh,
        prior_restatement_count
    from company_running
    where adsh is not null

)

select
    base.adsh,
    base.cik,
    base.form_type,
    base.filed_date,
    base.period_end_date,
    base.was_restated,

    base.filing_lag_days,
    base.is_large_accelerated_filer,
    base.is_accelerated_filer,
    base.is_non_accelerated_filer,
    base.custom_tag_share,

    -- Feature 4. Revisions to this company's earlier filings that had already
    -- been published when this one was filed. Zero for a company with no
    -- history rather than null: the reader knew of no prior restatement, which
    -- is a value and not a gap.
    coalesce(prior_restatements.prior_restatement_count, 0)     as prior_restatement_count,

    -- Feature 5. The restatement rate a reader could have computed for this
    -- sector on this date. Sectors fall back to the whole-market rate to date
    -- where nothing has resolved in them yet, which is early 2023 for everyone
    -- and permanently for the 2.5% of filings with no numeric SIC. The market
    -- rate itself is zero on the first horizon of the range, where nothing at
    -- all has resolved — a genuine absence of information, and one that only
    -- affects training rows.
    coalesce(
        case
            when base.sic_major_group_at_filing is not null
                and sector_rate.sector_prior_resolved > 0
            then sector_rate.sector_prior_restated::numeric
                 / sector_rate.sector_prior_resolved
        end,
        case
            when sector_rate.market_prior_resolved > 0
            then sector_rate.market_prior_restated::numeric
                 / sector_rate.market_prior_resolved
        end,
        0
    )                                                           as sector_restatement_rate,

    -- Diagnostics. How much history each feature was actually computed over,
    -- so a rate resting on nine prior filings is distinguishable from one
    -- resting on nine thousand.
    --
    -- The null-SIC guard is repeated here rather than left to the running sum.
    -- Filings with no numeric SIC share one null window partition, so the
    -- running sum does accumulate a count over them, but that count backs no
    -- rate: those filings read the market fallback. Reporting it would overstate
    -- the support behind the feature, and train_compare.py reads this column to
    -- identify rows whose sector rate had no history to compute from.
    base.sic_major_group_at_filing                              as sic_major_group,
    case
        when base.sic_major_group_at_filing is null then 0
        else coalesce(sector_rate.sector_prior_resolved, 0)
    end                                                         as sector_prior_resolved_filings,
    coalesce(sector_rate.market_prior_resolved, 0)              as market_prior_resolved_filings
from base
left join sector_rate
    on sector_rate.adsh = base.adsh
left join prior_restatements
    on prior_restatements.adsh = base.adsh
