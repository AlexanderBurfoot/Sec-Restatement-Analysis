{{
    config(
        materialized='table',
        pre_hook="set work_mem = '512MB'",
        indexes=[
            {'columns': ['restatement_sk'], 'type': 'btree'},
            {'columns': ['cik'], 'type': 'btree'},
            {'columns': ['tag'], 'type': 'btree'}
        ]
    )
}}

/*
  A restatement is one described fact reported at two different values by two
  filings published on different dates. The partition is what the fact
  describes; the ordering is when it was published. adsh is deliberately absent
  from the partition — comparing across filings is the entire mechanism.

  segments and coregistrant are in the partition, and they are load-bearing.
  Without segments a segment-level figure is compared against the consolidated
  total and 23.34% of multi-filing groups look restated; with it, 5.43%. Without
  coregistrant a subsidiary's own figure is compared against the parent's.
  Neither difference is a revision.

  taxonomy_version is deliberately absent: the same concept reported under
  us-gaap/2023 and us-gaap/2024 is the same fact, and for a company extension
  tag taxonomy_version is the accession number, so including it would put every
  custom tag in a partition of one and hide every restatement of one.

  All seven partition columns are not-null in fct_financial_fact and tested as
  such below, so the joins here use plain equality rather than the project's
  usual `is not distinct from`: a null-safe operator is not hashable and would
  turn a hash join over 30m rows into a nested loop.

  The work_mem pre-hook is not tuning for its own sake. The grouping sorts
  42.5m rows on a key that includes segments, which runs to 491 characters; at
  the server default of 64MB the planner chooses a sort and the model does not
  finish in twenty minutes, and with room for a hash aggregate the same
  grouping takes about a minute.

  Everything is anchored on the first reported value rather than on the previous
  one, so pct_revision, days_to_first_revision and revising_form_type all
  describe the same event: the departure from what was originally published.
*/

{% set rounding_threshold = var('restatement_rounding_threshold') %}

with reports as (

    -- One report per described fact per publication date. Facts whose value
    -- failed the safe_numeric cast are not reports of a number and cannot be
    -- compared; including them would read a null as a revision.
    --
    -- The array_agg picks the highest adsh where one date carries conflicting
    -- values for one fact. That affects 3,423 of 42,484,718 group-dates
    -- (0.008%): 150 are the known duplicate-composite-key defect inside a
    -- single filing, the rest are two filings published the same day. A
    -- tiebreaker is required for determinism and no tiebreaker is more correct
    -- than another, so the latest accession issued that day wins.
    select
        cik,
        coregistrant,
        segments,
        tag,
        period_end_date,
        qtrs,
        unit_of_measure,
        filed_date,
        (array_agg(value order by adsh desc))[1]    as reported_value,
        (array_agg(adsh order by adsh desc))[1]     as adsh
    from {{ ref('fct_financial_fact') }}
    where value is not null
    group by 1, 2, 3, 4, 5, 6, 7, 8

),

fact_groups as (

    -- The having clause is the definition of a candidate: reported more than
    -- once, on more than one date. 40,629 groups are reported by several
    -- filings that all published on a single day; no time elapsed between them,
    -- so nothing was revised and they are not candidates.
    select
        cik,
        coregistrant,
        segments,
        tag,
        period_end_date,
        qtrs,
        unit_of_measure,
        count(*)                                                        as n_reports,
        count(distinct reported_value)                                  as n_distinct_values,
        min(filed_date)                                                 as first_filed_date,
        max(filed_date)                                                 as latest_filed_date,
        (array_agg(reported_value order by filed_date))[1]              as first_reported_value,
        (array_agg(adsh order by filed_date))[1]                        as first_adsh,
        (array_agg(reported_value order by filed_date desc))[1]         as latest_reported_value,
        (array_agg(adsh order by filed_date desc))[1]                   as latest_adsh
    from reports
    group by 1, 2, 3, 4, 5, 6, 7
    having count(*) > 1
       and min(filed_date) < max(filed_date)

),

restated_groups as (

    -- pct_revision is a signed fraction of the originally reported value:
    -- 0.05 is a five percent upward revision. Null where the first reported
    -- value is zero, which has no scale to express a change against.
    select
        fact_groups.*,
        latest_reported_value - first_reported_value                    as absolute_revision,
        case
            when first_reported_value = 0 then null
            else (latest_reported_value - first_reported_value)
                 / abs(first_reported_value)
        end                                                             as pct_revision
    from fact_groups
    where latest_reported_value is distinct from first_reported_value

),

material_restatements as (

    -- The rounding threshold. A move off zero is material by fiat: with no
    -- denominator there is no ratio to test, and a figure that was zero and is
    -- now not zero is a change of kind rather than of precision.
    select *
    from restated_groups
    where pct_revision is null
       or abs(pct_revision) >= {{ rounding_threshold }}

),

reports_against_first as (

    select
        material_restatements.cik,
        material_restatements.coregistrant,
        material_restatements.segments,
        material_restatements.tag,
        material_restatements.period_end_date,
        material_restatements.qtrs,
        material_restatements.unit_of_measure,
        reports.filed_date,
        reports.adsh,
        reports.reported_value,
        material_restatements.first_reported_value
    from material_restatements
    join reports
        on  reports.cik             = material_restatements.cik
        and reports.coregistrant    = material_restatements.coregistrant
        and reports.segments        = material_restatements.segments
        and reports.tag             = material_restatements.tag
        and reports.period_end_date = material_restatements.period_end_date
        and reports.qtrs            = material_restatements.qtrs
        and reports.unit_of_measure = material_restatements.unit_of_measure
    where reports.filed_date > material_restatements.first_filed_date

),

first_revision as (

    -- The earliest publication that departed materially from what was first
    -- reported. Guaranteed to exist for every material_restatements row,
    -- because the latest report itself satisfies this predicate.
    select distinct on (
        cik, coregistrant, segments, tag, period_end_date, qtrs, unit_of_measure
    )
        cik,
        coregistrant,
        segments,
        tag,
        period_end_date,
        qtrs,
        unit_of_measure,
        filed_date                                                      as first_revision_filed_date,
        adsh                                                            as revising_adsh
    from reports_against_first
    where reported_value is distinct from first_reported_value
      and (
            first_reported_value = 0
            or abs((reported_value - first_reported_value)
                   / abs(first_reported_value)) >= {{ rounding_threshold }}
          )
    order by
        cik, coregistrant, segments, tag, period_end_date, qtrs, unit_of_measure,
        filed_date

)

select
    {{ dbt_utils.generate_surrogate_key([
        'material_restatements.cik',
        'material_restatements.coregistrant',
        'material_restatements.segments',
        'material_restatements.tag',
        'material_restatements.period_end_date',
        'material_restatements.qtrs',
        'material_restatements.unit_of_measure'
    ]) }}                                                               as restatement_sk,

    -- The partition key, carried in full.
    material_restatements.cik,
    material_restatements.coregistrant,
    material_restatements.segments,
    material_restatements.tag,
    material_restatements.period_end_date,
    material_restatements.qtrs,
    material_restatements.unit_of_measure,

    material_restatements.first_reported_value,
    material_restatements.first_filed_date,
    material_restatements.first_adsh,

    material_restatements.latest_reported_value,
    material_restatements.latest_filed_date,
    material_restatements.latest_adsh,

    material_restatements.n_reports,
    material_restatements.n_distinct_values,

    material_restatements.absolute_revision,
    material_restatements.pct_revision,

    first_revision.first_revision_filed_date,
    first_revision.revising_adsh,
    first_revision.first_revision_filed_date
        - material_restatements.first_filed_date                        as days_to_first_revision,
    revising_filing.form_type                                           as revising_form_type,

    case
        when material_restatements.absolute_revision > 0 then 'increase'
        else 'decrease'
    end                                                                 as revision_direction
from material_restatements

join first_revision
    on  first_revision.cik              = material_restatements.cik
    and first_revision.coregistrant     = material_restatements.coregistrant
    and first_revision.segments         = material_restatements.segments
    and first_revision.tag              = material_restatements.tag
    and first_revision.period_end_date  = material_restatements.period_end_date
    and first_revision.qtrs             = material_restatements.qtrs
    and first_revision.unit_of_measure  = material_restatements.unit_of_measure

-- Left joined: the form type is an attribute of the revising filing, and a
-- restatement stays a restatement if dim_filing ever fails to resolve it.
left join {{ ref('dim_filing') }} as revising_filing
    on revising_filing.adsh = first_revision.revising_adsh
