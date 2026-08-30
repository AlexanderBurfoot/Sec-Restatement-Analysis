{{ config(materialized='table') }}

/*
  Which companies restate repeatedly, and is it a run or a scatter?

  Five consecutive bad quarters and five scattered over three years are
  different failures, and a count cannot tell them apart. Islands over each
  company's own reporting timeline separate them: the timeline is the quarters
  the company actually filed for, so a gap means it did not report, not that it
  reported cleanly.
*/

{% set min_periods_for_ranking = 4 %}
{% set consecutive_run_min_length = 3 %}
{% set ntile_buckets = 10 %}

with company_periods as (

    -- The company's own reporting timeline. Taken from its filings rather than
    -- from a calendar, because "consecutive periods" has to mean consecutive
    -- periods it reported: a company that skipped a year has no clean quarter
    -- there to interrupt a run.
    select distinct
        cik,
        date_trunc('quarter', period_end_date)::date            as period_quarter
    from {{ ref('dim_filing') }}
    where period_end_date is not null

),

restated_periods as (

    select
        cik,
        date_trunc('quarter', period_end_date)::date            as period_quarter,
        count(*)                                                as restatements,
        count(*) filter (where revision_direction = 'decrease')  as downward_restatements,
        max(abs(pct_revision))                                  as max_abs_pct_revision
    from {{ ref('int_restatements') }}
    group by 1, 2

),

marked_timeline as (

    -- Restated periods outside the company's filing timeline are dropped from
    -- the run logic on purpose: a 2023 filing revising a 2019 comparative says
    -- nothing about whether 2019 was a consecutive bad quarter for a filer that
    -- was not reporting then. Those restatements are still counted in the
    -- totals below.
    select
        periods.cik,
        periods.period_quarter,
        (restated.cik is not null)                              as has_restatement,
        coalesce(restated.restatements, 0)                      as restatements,
        row_number() over (
            partition by periods.cik order by periods.period_quarter
        )                                                       as period_seq
    from company_periods as periods
    left join restated_periods as restated
        on  restated.cik = periods.cik
        and restated.period_quarter = periods.period_quarter

),

islanded as (

    -- Gap and island. Subtracting a dense sequence over the restated periods
    -- from the sequence over all periods leaves a constant for each unbroken
    -- run and a different constant either side of any gap.
    select
        cik,
        period_quarter,
        period_seq,
        restatements,
        period_seq - row_number() over (
            partition by cik order by period_seq
        )                                                       as island_key
    from marked_timeline
    where has_restatement

),

runs as (

    select
        cik,
        island_key,
        count(*)                                                as run_length,
        min(period_quarter)                                     as run_start_quarter,
        max(period_quarter)                                     as run_end_quarter,
        sum(restatements)                                       as restatements_in_run
    from islanded
    group by cik, island_key

),

run_summary as (

    select
        cik,
        count(*)                                                as n_runs,
        max(run_length)                                         as longest_run_periods,
        (array_agg(run_start_quarter order by run_length desc, run_start_quarter))[1]
                                                                as longest_run_start_quarter,
        (array_agg(run_end_quarter   order by run_length desc, run_start_quarter))[1]
                                                                as longest_run_end_quarter
    from runs
    group by cik

),

timeline_summary as (

    select
        cik,
        count(*)                                                as n_reporting_periods,
        count(*) filter (where has_restatement)                 as n_restated_periods,
        min(period_quarter)                                     as first_reporting_quarter,
        max(period_quarter)                                     as last_reporting_quarter
    from marked_timeline
    group by cik

),

company_totals as (

    -- Every restatement the filer owns, including those attached to periods
    -- outside its reporting timeline, so the totals reconcile to
    -- int_restatements even though the run logic does not use them all.
    select
        cik,
        count(*)                                                as total_restatements,
        count(*) filter (where revision_direction = 'decrease')  as downward_restatements,
        count(distinct tag)                                     as distinct_tags_restated,
        percentile_cont(0.5) within group (order by abs(pct_revision))
                                                                as median_abs_pct_revision
    from {{ ref('int_restatements') }}
    group by cik

),

company_labels as (

    select cik, company_name, sic_code
    from {{ ref('dim_company') }}
    where is_current

),

assembled as (

    select
        timeline.cik,
        labels.company_name,
        labels.sic_code,
        timeline.n_reporting_periods,
        timeline.n_restated_periods,
        timeline.first_reporting_quarter,
        timeline.last_reporting_quarter,
        coalesce(runs_agg.n_runs, 0)                            as n_restatement_runs,
        coalesce(runs_agg.longest_run_periods, 0)               as longest_run_periods,
        runs_agg.longest_run_start_quarter,
        runs_agg.longest_run_end_quarter,
        coalesce(totals.total_restatements, 0)                  as total_restatements,
        coalesce(totals.downward_restatements, 0)               as downward_restatements,
        coalesce(totals.distinct_tags_restated, 0)              as distinct_tags_restated,
        totals.median_abs_pct_revision,
        timeline.n_restated_periods::numeric
            / nullif(timeline.n_reporting_periods, 0)           as restated_period_rate
    from timeline_summary as timeline
    left join run_summary as runs_agg  on runs_agg.cik = timeline.cik
    left join company_totals as totals on totals.cik = timeline.cik
    left join company_labels as labels on labels.cik = timeline.cik

),

rankable as (

    -- The decile population, filtered before the window rather than after it.
    -- A company with one reported period and one restated period sits at 100%
    -- and would otherwise top every decile; masking it downstream still lets it
    -- consume a slot, which is what left the buckets uneven. The four-period
    -- floor is a judgement call, not a bound derived from the data.
    select
        cik,
        ntile({{ ntile_buckets }}) over (
            order by restated_period_rate, total_restatements
        )                                                       as restatement_rate_decile
    from assembled
    where n_reporting_periods >= {{ min_periods_for_ranking }}

),

ranked as (

    -- Left joined, so filers below the floor keep every other measure and carry
    -- a null decile rather than dropping out of the model entirely.
    select
        assembled.*,
        rankable.restatement_rate_decile
    from assembled
    left join rankable
        on rankable.cik = assembled.cik

)

select
    cik,
    company_name,
    sic_code,
    n_reporting_periods,
    n_restated_periods,
    first_reporting_quarter,
    last_reporting_quarter,
    total_restatements,
    distinct_tags_restated,
    round(100.0 * restated_period_rate, 2)                      as pct_periods_restated,
    round(100.0 * downward_restatements / nullif(total_restatements, 0), 2)
                                                                as pct_restatements_downward,
    round(median_abs_pct_revision::numeric, 4)                  as median_abs_pct_revision,

    n_restatement_runs,
    longest_run_periods,
    longest_run_start_quarter,
    longest_run_end_quarter,
    restatement_rate_decile,
    (n_reporting_periods >= {{ min_periods_for_ranking }})      as is_rankable,

    -- The distinction the model exists to draw. Sustained means the bad periods
    -- ran back to back; scattered means the same number of bad periods arrived
    -- separated by clean ones.
    case
        when n_restated_periods = 0 then 'none'
        when n_restated_periods = 1 then 'isolated'
        when longest_run_periods >= {{ consecutive_run_min_length }}
            then 'sustained_run'
        when n_restatement_runs >= 3 then 'scattered'
        else 'intermittent'
    end                                                         as restatement_pattern

from ranked
order by restated_period_rate desc nulls last, total_restatements desc
