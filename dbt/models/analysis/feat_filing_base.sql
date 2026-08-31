{{
    config(
        materialized='table',
        pre_hook="set work_mem = '512MB'"
    )
}}

/*
  The population, the label, and the features that are the same under both
  visibility rules. feat_filing_pit and feat_filing_naive both read this and add
  only the two features whose value depends on what the reader is allowed to
  see, so the pair cannot drift on anything except the leak being measured.

  The label is fixed at a horizon rather than left open. A filing is restated if
  it published a consolidated figure that a later filing revised within
  {{ var('restatement_label_horizon_days') }} days of it. Filings within one
  horizon of the end of the loaded range have no complete observation window and
  are not in the population at all — labelling them zero would record an
  unfinished wait as a clean filing.

  Consolidated means segments and coregistrant both empty. Segment-level and
  subsidiary-level revisions are real, and counting them raises the positive
  rate from 11.65% to 20.75%, but most of that increase is the re-tagging of
  dimensional breakdowns rather than a revision to the headline financials the
  label is meant to name.
*/

{% set label_horizon_days = var('restatement_label_horizon_days') %}

with loaded_range as (

    -- Read from the data rather than written down, so the population shrinks on
    -- its own when a later quarter is loaded instead of silently going stale.
    select max(filed_date) as last_filed_date
    from {{ ref('stg_submissions') }}

),

population as (

    -- Periodic reports only, and originals only: the exact form codes exclude
    -- 10-K/A and 10-Q/A, which are themselves the revisions this predicts.
    select
        submissions.adsh,
        submissions.cik,
        submissions.filed_date,
        submissions.period_end_date,
        submissions.form_type,
        submissions.filer_status,
        submissions.filing_lag_days
    from {{ ref('stg_submissions') }} as submissions
    cross join loaded_range
    where submissions.form_type in ('10-K', '10-Q')
      and submissions.filed_date + {{ label_horizon_days }} <= loaded_range.last_filed_date

),

revised_filings as (

    -- One row per filing that originated a consolidated figure later revised,
    -- carrying the date the earliest such revision was published. That date is
    -- when the revision became knowable, and the point-in-time features are
    -- built on it.
    --
    -- int_restatements has already applied the rounding threshold, so no second
    -- materiality bound is imposed here. One was tested and does almost nothing:
    -- requiring the revision to exceed five percent moves the positive rate from
    -- 11.44% to 9.41%. The horizon, not the magnitude, is what makes this label
    -- mean something.
    select
        first_adsh                          as adsh,
        min(first_revision_filed_date)      as revision_first_seen_date
    from {{ ref('int_restatements') }}
    where segments = ''
      and coregistrant = ''
    group by first_adsh

),

tag_mix as (

    -- Share of the filing's own facts carried on a company extension tag. A
    -- property of the filing as published, so it reads the same under both
    -- visibility rules.
    select
        facts.adsh,
        count(*)                                    as n_facts,
        count(*) filter (where tags.is_custom)      as n_custom_facts
    from {{ ref('fct_financial_fact') }} as facts
    join population
        on population.adsh = facts.adsh
    left join {{ ref('dim_tag') }} as tags
        on tags.tag_sk = facts.tag_sk
    group by facts.adsh

),

sector_at_filing as (

    -- SIC as the filer reported it on the day, from the Type 2 version current
    -- then. This is the sector a point-in-time reader would have grouped the
    -- filing under.
    select
        population.adsh,
        case
            when dim_company.sic_code ~ '^[0-9]{4}$'
                then left(dim_company.sic_code, 2)
        end                                         as sic_major_group
    from population
    join {{ ref('dim_company') }} as dim_company
        on  dim_company.cik = population.cik
        and population.filed_date between dim_company.valid_from and dim_company.valid_to

),

sector_now as (

    -- SIC as it stands today. Differs from the above wherever a filer
    -- reclassified after the filing, which is one of the two things the naive
    -- feature table is allowed to see.
    select
        population.adsh,
        case
            when dim_company.sic_code ~ '^[0-9]{4}$'
                then left(dim_company.sic_code, 2)
        end                                         as sic_major_group
    from population
    join {{ ref('dim_company') }} as dim_company
        on  dim_company.cik = population.cik
        and dim_company.is_current

)

select
    population.adsh,
    population.cik,
    population.form_type,

    -- Both dates, never collapsed. filed_date is the split boundary and the
    -- as-of date every point-in-time feature is evaluated against.
    population.filed_date,
    population.period_end_date,

    -- The label, and the date it became knowable. revision_first_seen_date is
    -- deliberately not truncated to the horizon: a revision published on day 400
    -- did not meet the label, but a reader on day 401 knew about it, and the
    -- point-in-time prior-restatement count is built on knowability.
    (revised_filings.revision_first_seen_date
        <= population.filed_date + {{ label_horizon_days }})
        is true                                             as was_restated,
    revised_filings.revision_first_seen_date,

    -- Feature 1. Days the number spent unknowable.
    population.filing_lag_days,

    -- Feature 2. Filer status as three indicators. `is true` rather than a bare
    -- comparison because exactly one filing in the population reports no status,
    -- and a bare comparison would make all three indicators null on it rather
    -- than all three false. All-false is the intended encoding: that filing is
    -- the reference category, alone, instead of joining a real one.
    population.filer_status,
    (population.filer_status = '1-LAF') is true              as is_large_accelerated_filer,
    (population.filer_status = '2-ACC') is true              as is_accelerated_filer,
    (population.filer_status = '4-NON') is true              as is_non_accelerated_filer,

    -- Feature 3. Company extension tags as a share of the filing's facts.
    tag_mix.n_facts,
    tag_mix.n_custom_facts,
    tag_mix.n_custom_facts::numeric
        / nullif(tag_mix.n_facts, 0)                        as custom_tag_share,

    -- Carried for features 4 and 5, which the two downstream models compute
    -- from these under their own visibility rule.
    sector_at_filing.sic_major_group                        as sic_major_group_at_filing,
    sector_now.sic_major_group                              as sic_major_group_now
from population
left join revised_filings
    on revised_filings.adsh = population.adsh
left join tag_mix
    on tag_mix.adsh = population.adsh
left join sector_at_filing
    on sector_at_filing.adsh = population.adsh
left join sector_now
    on sector_now.adsh = population.adsh
