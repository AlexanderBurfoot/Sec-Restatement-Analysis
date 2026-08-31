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
  from the partition, comparing across filings is the entire mechanism.

  segments and coregistrant are in the partition, and they are load-bearing.
  Without segments a segment-level figure is compared against the consolidated
  total; without coregistrant a subsidiary's own figure is compared against the
  parent's. Neither difference is a revision. Measured on the loaded range,
  restated groups as a share of groups reported by more than one filing are
  16.46% on (cik, tag, period, qtrs, uom) alone, 15.90% adding coregistrant,
  and 4.77% adding segments. segments is what does the work; coregistrant is
  cheap correctness rather than a large effect.

  taxonomy_version is deliberately absent: the same concept reported under
  us-gaap/2023 and us-gaap/2024 is the same fact, and for a company extension
  tag taxonomy_version is the accession number, so including it would put every
  custom tag in a partition of one and hide every restatement of one.

  Everything is anchored on the first reported value rather than on the previous
  one, so pct_revision, days_to_first_revision and revising_form_type all
  describe the same event: the departure from what was originally published.

  Shape: the whole model is one pass over one sort. reports is read exactly
  once, a window over (partition key, filed_date) carries the first and latest
  report onto every row and flags the ones that departed materially, and the
  group by then collapses that same ordering. An earlier formulation found the
  first revision by joining reports back to itself on all seven columns; that
  built a hash table over 42.5m rows keyed partly on segments, which runs to
  491 characters, and did not finish in fifty minutes. Nothing here re-reads
  the fact table to answer a question the first read already had in hand.
*/

{% set rounding_threshold = var('restatement_rounding_threshold') %}

with reports as (

    -- One report per described fact per publication date. Facts whose value
    -- failed the safe_numeric cast are not reports of a number and cannot be
    -- compared; including them would read a null as a revision.
    --
    -- The array_agg picks the highest adsh where one date carries conflicting
    -- values for one fact: partly two filings published the same day, partly
    -- the known duplicate-composite-key defect inside a single filing. A
    -- tiebreaker is required for determinism and no tiebreaker is more correct
    -- than another, so the latest accession issued that day wins.
    --
    -- value is the second tiebreaker and it is not decorative. In the defect
    -- case the two conflicting rows carry the *same* adsh, so adsh alone
    -- leaves the choice to whatever order the scan happened to return, and the
    -- model is then not idempotent: two consecutive builds differed by three
    -- rows and produced different checksums. Ordering by value as well makes
    -- the pick total. Both aggregates use the identical ordering so they read
    -- the value and the accession off the same row.
    --
    -- Collapsing to one row per date is also what makes the having clause
    -- below sufficient: within a partition every filed_date is now distinct.
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

against_first as (

    -- The frame is stated explicitly. The default frame runs to the current
    -- row, which would make last_value return the row it is called on rather
    -- than the last report in the group.
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
        first_value(reported_value) over w                              as first_reported_value,
        first_value(filed_date)     over w                              as first_filed_date,
        first_value(adsh)           over w                              as first_adsh,
        last_value(reported_value)  over w                              as latest_reported_value,
        last_value(filed_date)      over w                              as latest_filed_date,
        last_value(adsh)            over w                              as latest_adsh
    from reports
    window w as (
        partition by
            cik, coregistrant, segments, tag, period_end_date, qtrs, unit_of_measure
        order by filed_date
        rows between unbounded preceding and unbounded following
    )

),

flagged as (

    -- A report departs materially if it was published later than the first,
    -- differs from it, and differs by at least the rounding threshold. Applied
    -- per report rather than only to the latest, so days_to_first_revision
    -- measures the first genuine departure and not the first rounding wobble.
    select
        against_first.*,
        filed_date > first_filed_date
        and reported_value is distinct from first_reported_value
        and (
                first_reported_value = 0
                or abs((reported_value - first_reported_value)
                       / abs(first_reported_value)) >= {{ rounding_threshold }}
            )                                                           as is_material_departure
    from against_first

),

fact_groups as (

    -- first_* and latest_* are constant within the group, so min() is just a
    -- way of carrying a constant through the aggregation.
    --
    -- The having clause is the definition of a candidate: reported on more than
    -- one date. Groups reported by several filings that all published on a
    -- single day collapsed to one row in reports and are excluded here; no time
    -- elapsed between them, so nothing was revised.
    select
        cik,
        coregistrant,
        segments,
        tag,
        period_end_date,
        qtrs,
        unit_of_measure,
        min(first_reported_value)                                       as first_reported_value,
        min(first_filed_date)                                           as first_filed_date,
        min(first_adsh)                                                 as first_adsh,
        min(latest_reported_value)                                      as latest_reported_value,
        min(latest_filed_date)                                          as latest_filed_date,
        min(latest_adsh)                                                as latest_adsh,
        count(*)                                                        as n_reports,
        count(distinct reported_value)                                  as n_distinct_values,
        min(filed_date) filter (where is_material_departure)             as first_revision_filed_date,
        (array_agg(adsh order by filed_date)
            filter (where is_material_departure))[1]                    as revising_adsh
    from flagged
    group by 1, 2, 3, 4, 5, 6, 7
    having count(*) > 1

),

restated_groups as (

    -- pct_revision is a signed fraction of the originally reported value:
    -- 0.05 is a five percent upward revision. Null where the first reported
    -- value is zero, which has no scale to express a change against.
    --
    -- A figure revised away and then restored to its original value is not a
    -- restatement here, because the test is first against latest. n_reports
    -- and n_distinct_values are what expose that case.
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
    --
    -- first_revision_filed_date is non-null for every row that survives here:
    -- the latest report is itself a material departure whenever first and
    -- latest differ materially, so the filter above cannot select a group whose
    -- flag never fired.
    select *
    from restated_groups
    where pct_revision is null
       or abs(pct_revision) >= {{ rounding_threshold }}

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

    material_restatements.first_revision_filed_date,
    material_restatements.revising_adsh,
    material_restatements.first_revision_filed_date
        - material_restatements.first_filed_date                        as days_to_first_revision,
    revising_filing.form_type                                           as revising_form_type,

    case
        when material_restatements.absolute_revision > 0 then 'increase'
        else 'decrease'
    end                                                                 as revision_direction
from material_restatements

-- Left joined: the form type is an attribute of the revising filing, and a
-- restatement stays a restatement if dim_filing ever fails to resolve it.
left join {{ ref('dim_filing') }} as revising_filing
    on revising_filing.adsh = material_restatements.revising_adsh
