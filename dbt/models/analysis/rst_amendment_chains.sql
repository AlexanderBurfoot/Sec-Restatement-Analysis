{{
    config(
        materialized='table',
        pre_hook="set work_mem = '512MB'"
    )
}}

/*
  Does one restatement predict another?

  int_restatements answers first-value against latest-value, which collapses a
  fact revised three times into one row. A chain needs the steps between, so the
  report sequence is rebuilt here and walked recursively: each link is a
  material change from the *previous* report, not from the first, and a fact
  revised three times becomes one chain of length three.
*/

{% set rounding_threshold = var('restatement_rounding_threshold') %}
{% set long_chain_min_length = 3 %}
{% set top_filers = 25 %}

with recursive reports as (

    -- One report per described fact per publication date, collapsed on the same
    -- rule int_restatements uses: highest accession that day, then highest
    -- value. The tiebreak has to match, or a chain would count a revision that
    -- the restatement model does not recognise.
    select
        cik,
        coregistrant,
        segments,
        tag,
        period_end_date,
        qtrs,
        unit_of_measure,
        filed_date,
        (array_agg(value order by adsh desc, value desc))[1]    as reported_value,
        (array_agg(adsh order by adsh desc, value desc))[1]     as adsh
    from {{ ref('fct_financial_fact') }}
    where value is not null
    group by 1, 2, 3, 4, 5, 6, 7, 8

),

against_previous as (

    select
        cik,
        coregistrant,
        segments,
        tag,
        period_end_date,
        qtrs,
        unit_of_measure,
        filed_date,
        adsh,
        reported_value,
        lag(reported_value) over report_sequence                as previous_value,
        lag(filed_date)     over report_sequence                as previous_filed_date,
        lag(adsh)           over report_sequence                as previous_adsh
    from reports
    window report_sequence as (
        partition by
            cik, coregistrant, segments, tag, period_end_date, qtrs, unit_of_measure
        order by filed_date
    )

),

revision_steps as (

    -- One row per revision event. The surrogate key is built here rather than
    -- upstream so the hash runs over the few hundred thousand rows that are
    -- revisions, not over the forty million reports that are not.
    select
        {{ dbt_utils.generate_surrogate_key([
            'cik', 'coregistrant', 'segments', 'tag',
            'period_end_date', 'qtrs', 'unit_of_measure'
        ]) }}                                                   as restatement_sk,
        cik,
        tag,
        previous_adsh,
        adsh,
        previous_filed_date,
        filed_date,
        previous_value,
        reported_value,
        row_number() over (
            partition by
                cik, coregistrant, segments, tag,
                period_end_date, qtrs, unit_of_measure
            order by filed_date
        )                                                       as step_seq
    from against_previous
    where previous_value is not null
      and reported_value is distinct from previous_value
      and (
            previous_value = 0
            or abs((reported_value - previous_value) / abs(previous_value))
                   >= {{ rounding_threshold }}
          )

),

chain_walk as (

    -- Anchored on each fact's first revision, then extended one step at a time.
    -- The recursion carries the path of accession numbers and the value the
    -- chain started from, neither of which a plain aggregate over the steps
    -- could produce in order.
    select
        restatement_sk,
        cik,
        step_seq,
        1                                                       as chain_length,
        array[previous_adsh, adsh]                              as adsh_path,
        previous_value                                          as chain_first_value,
        reported_value                                          as chain_latest_value,
        previous_filed_date                                     as chain_start_date,
        filed_date                                              as chain_end_date
    from revision_steps
    where step_seq = 1

    union all

    select
        next_step.restatement_sk,
        next_step.cik,
        next_step.step_seq,
        walked.chain_length + 1,
        walked.adsh_path || next_step.adsh,
        walked.chain_first_value,
        next_step.reported_value,
        walked.chain_start_date,
        next_step.filed_date
    from chain_walk as walked
    join revision_steps as next_step
        on  next_step.restatement_sk = walked.restatement_sk
        and next_step.step_seq       = walked.step_seq + 1

),

completed_chains as (

    -- The walk emits a row at every depth; the longest is the whole chain.
    select distinct on (restatement_sk)
        restatement_sk,
        cik,
        chain_length,
        adsh_path,
        chain_first_value,
        chain_latest_value,
        chain_start_date,
        chain_end_date,
        chain_end_date - chain_start_date                       as chain_span_days
    from chain_walk
    order by restatement_sk, chain_length desc

),

company_labels as (

    select cik, company_name
    from {{ ref('dim_company') }}
    where is_current

),

length_distribution as (

    select
        'chain_length_distribution'                             as result_scope,
        chain_length::text                                      as result_key,
        null::text                                              as company_name,
        count(*)                                                as chains,
        count(distinct cik)                                     as companies,
        round(avg(chain_span_days)::numeric, 1)                 as mean_chain_span_days,
        round(percentile_cont(0.5) within group (
            order by chain_span_days
        )::numeric, 1)                                          as median_chain_span_days,
        null::bigint                                            as long_chains,
        null::numeric                                           as pct_chains_long
    from completed_chains
    group by chain_length

),

filer_concentration as (

    -- The predictive question, read at filer grain: a company whose chains are
    -- mostly length one revises and stops, while one with a high share of long
    -- chains revises the same figure repeatedly.
    select
        'filer_concentration'                                   as result_scope,
        chains.cik::text                                        as result_key,
        labels.company_name,
        count(*)                                                as chains,
        1::bigint                                               as companies,
        round(avg(chains.chain_span_days)::numeric, 1)          as mean_chain_span_days,
        round(percentile_cont(0.5) within group (
            order by chains.chain_span_days
        )::numeric, 1)                                          as median_chain_span_days,
        count(*) filter (
            where chains.chain_length >= {{ long_chain_min_length }}
        )                                                       as long_chains,
        round(100.0 * count(*) filter (
            where chains.chain_length >= {{ long_chain_min_length }}
        ) / nullif(count(*), 0), 2)                             as pct_chains_long
    from completed_chains as chains
    left join company_labels as labels
        on labels.cik = chains.cik
    group by chains.cik, labels.company_name
    order by long_chains desc, chains desc
    limit {{ top_filers }}

)

select * from length_distribution
union all
select * from filer_concentration
order by result_scope, long_chains desc nulls last, chains desc
