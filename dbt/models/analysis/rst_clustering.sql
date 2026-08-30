{{
    config(
        materialized='table',
        pre_hook="set work_mem = '512MB'"
    )
}}

/*
  Do restatements bunch in particular quarters, or arrive at a steady rate?

  Asked on two clocks, because "when" is ambiguous here: the quarter a revision
  was published, and the quarter whose figures it revised. Both carry a
  denominator, since a raw count would only rediscover that more filings arrive
  in 10-K season, which is filing seasonality rather than restatement clustering.
*/

{% set trailing_quarters = 4 %}

with quarter_spine as (

    -- A row per calendar quarter, so the trailing average is a genuine time
    -- window. Counting over whichever quarters happen to be non-empty would
    -- silently close gaps and average across a hole as though it were adjacent.
    select distinct
        date_trunc('quarter', date_day)::date                   as quarter_start_date
    from {{ ref('dim_date') }}

),

revisions_by_filed_quarter as (

    select
        date_trunc('quarter', first_revision_filed_date)::date  as quarter_start_date,
        count(*)                                                as restatements,
        count(distinct cik)                                     as restating_companies,
        count(*) filter (where revision_direction = 'decrease')  as downward_restatements
    from {{ ref('int_restatements') }}
    group by 1

),

filings_by_filed_quarter as (

    select
        date_trunc('quarter', filed_date)::date                 as quarter_start_date,
        count(*)                                                as denominator
    from {{ ref('dim_filing') }}
    group by 1

),

revisions_by_period_quarter as (

    select
        date_trunc('quarter', period_end_date)::date            as quarter_start_date,
        count(*)                                                as restatements,
        count(distinct cik)                                     as restating_companies,
        count(*) filter (where revision_direction = 'decrease')  as downward_restatements
    from {{ ref('int_restatements') }}
    group by 1

),

revisable_groups as (

    select
        period_end_date
    from {{ ref('fct_financial_fact') }}
    where value is not null
    group by cik, coregistrant, segments, tag, period_end_date, qtrs, unit_of_measure
    having count(distinct filed_date) > 1

),

revisable_by_period_quarter as (

    select
        date_trunc('quarter', period_end_date)::date            as quarter_start_date,
        count(*)                                                as denominator
    from revisable_groups
    group by 1

),

both_bases as (

    -- The two clocks take different denominators and that is deliberate. A
    -- revision has a publication date, so it divides by filings published then;
    -- a described fact has no publication date, so the period clock divides by
    -- the facts describing that period which could have been revised.
    select
        'revision_filed'                                        as quarter_basis,
        'filings_published_in_quarter'                          as denominator_kind,
        revisions.quarter_start_date,
        revisions.restatements,
        revisions.restating_companies,
        revisions.downward_restatements,
        filings.denominator
    from revisions_by_filed_quarter as revisions
    left join filings_by_filed_quarter as filings
        using (quarter_start_date)

    union all

    select
        'period_restated',
        'revisable_facts_for_period',
        revisions.quarter_start_date,
        revisions.restatements,
        revisions.restating_companies,
        revisions.downward_restatements,
        revisable.denominator
    from revisions_by_period_quarter as revisions
    left join revisable_by_period_quarter as revisable
        using (quarter_start_date)

),

basis_bounds as (

    select
        quarter_basis,
        min(quarter_start_date)                                 as first_quarter,
        max(quarter_start_date)                                 as last_quarter
    from both_bases
    group by quarter_basis

),

dense_series as (

    -- Every quarter between each basis's own first and last observation, empty
    -- ones included at zero.
    select
        bounds.quarter_basis,
        spine.quarter_start_date,
        coalesce(observed.restatements, 0)                      as restatements,
        coalesce(observed.restating_companies, 0)               as restating_companies,
        coalesce(observed.downward_restatements, 0)             as downward_restatements,
        observed.denominator,
        max(observed.denominator_kind) over (
            partition by bounds.quarter_basis
        )                                                       as denominator_kind
    from basis_bounds as bounds
    join quarter_spine as spine
        on spine.quarter_start_date
               between bounds.first_quarter and bounds.last_quarter
    left join both_bases as observed
        on  observed.quarter_basis = bounds.quarter_basis
        and observed.quarter_start_date = spine.quarter_start_date

),

rated as (

    select
        dense_series.*,
        1000.0 * restatements / nullif(denominator, 0)          as restatements_per_1k
    from dense_series

),

with_trailing as (

    -- The window excludes the current quarter, so a spike is measured against
    -- the level before it rather than against a baseline it is itself inflating.
    select
        rated.*,
        avg(restatements) over trailing_window                  as trailing_avg_restatements,
        avg(restatements_per_1k) over trailing_window                  as trailing_avg_rate,
        count(*) over trailing_window                  as trailing_quarters_available
    from rated
    window trailing_window as (
        partition by quarter_basis
        order by quarter_start_date
        rows between {{ trailing_quarters }} preceding and 1 preceding
    )

)

select
    quarter_basis,
    denominator_kind,
    quarter_start_date,
    extract(year from quarter_start_date)::int                  as calendar_year,
    extract(quarter from quarter_start_date)::int               as calendar_quarter,

    restatements,
    restating_companies,
    denominator,
    round(restatements_per_1k::numeric, 3)                      as restatements_per_1k,
    round(100.0 * downward_restatements / nullif(restatements, 0), 2)
                                                                as pct_restatements_downward,

    round(trailing_avg_restatements::numeric, 1)                as trailing_avg_restatements,
    round(trailing_avg_rate::numeric, 3)                        as trailing_avg_rate,

    -- Above 1 means the quarter ran hotter than the four before it. Reported on
    -- the rate as well as the count, because the count ratio moves with filing
    -- volume alone.
    round((restatements / nullif(trailing_avg_restatements, 0))::numeric, 3)
                                                                as count_vs_trailing,
    round((restatements_per_1k / nullif(trailing_avg_rate, 0))::numeric, 3)
                                                                as rate_vs_trailing,

    -- Null until a full trailing window exists, so the opening quarters of each
    -- series are not read as findings.
    (trailing_quarters_available = {{ trailing_quarters }})     as has_full_trailing_window

from with_trailing
order by quarter_basis, quarter_start_date
