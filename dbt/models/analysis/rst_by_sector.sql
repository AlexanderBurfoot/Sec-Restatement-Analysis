{{
    config(
        materialized='table',
        pre_hook="set work_mem = '512MB'"
    )
}}

/*
  Which industries restate most?

  Sector is the SIC on the dim_company version current when the fact was first
  published, never the filer's present-day SIC, so a company that reclassified
  is counted under the industry it reported from at the time. Count alone
  answers nothing, a large sector restates more by filing more, so the same
  as-at rule attributes the denominators too.
*/

with company_sector as (

    -- SIC divisions are contiguous ranges over the four-digit code, so the
    -- mapping is derived rather than stored. Defined once here and joined by
    -- all three aggregations below, so numerator and denominators cannot drift
    -- apart on how a code is classified.
    select
        cik,
        valid_from,
        valid_to,
        sic_code,

        case
            when sic_code !~ '^[0-9]{4}$' then 'Unclassified'
            when sic_code::int between  100 and  999 then 'Agriculture, Forestry & Fishing'
            when sic_code::int between 1000 and 1499 then 'Mining'
            when sic_code::int between 1500 and 1799 then 'Construction'
            when sic_code::int between 2000 and 3999 then 'Manufacturing'
            when sic_code::int between 4000 and 4999 then 'Transport, Comms & Utilities'
            when sic_code::int between 5000 and 5199 then 'Wholesale Trade'
            when sic_code::int between 5200 and 5999 then 'Retail Trade'
            when sic_code::int between 6000 and 6799 then 'Finance, Insurance & Real Estate'
            when sic_code::int between 7000 and 8999 then 'Services'
            when sic_code::int between 9100 and 9729 then 'Public Administration'
            else 'Unclassified'
        end                                                     as sic_division,

        -- The two-digit major group, one level finer than the division.
        case
            when sic_code ~ '^[0-9]{4}$' then left(sic_code, 2)
            else null
        end                                                     as sic_major_group

    from {{ ref('dim_company') }}

),

revisable_groups as (

    -- The denominator a restatement rate actually needs: described facts that
    -- were reported on more than one date and so had the opportunity to be
    -- revised. Facts reported once can never restate and would only dilute the
    -- rate. This is the same population int_restatements filters down from.
    select
        cik,
        min(filed_date)                                         as first_filed_date
    from {{ ref('fct_financial_fact') }}
    where value is not null
    group by cik, coregistrant, segments, tag, period_end_date, qtrs, unit_of_measure
    having count(distinct filed_date) > 1

),

revisable_by_sector as (

    select
        sector.sic_division,
        sector.sic_major_group,
        grouping(sector.sic_division, sector.sic_major_group)   as grouping_level,
        count(*)                                                as revisable_groups
    from revisable_groups as groups
    left join company_sector as sector
        on  sector.cik = groups.cik
        and groups.first_filed_date between sector.valid_from and sector.valid_to
    group by grouping sets (
        (sector.sic_division, sector.sic_major_group),
        (sector.sic_division),
        ()
    )

),

restated_by_sector as (

    -- Attributed on first_filed_date, the same date rule as the denominator:
    -- the sector the original number was published from. Attributing the
    -- numerator on the revision date instead would let a reclassification move
    -- a restatement into a sector whose denominator never carried the fact.
    select
        sector.sic_division,
        sector.sic_major_group,
        grouping(sector.sic_division, sector.sic_major_group)   as grouping_level,
        count(*)                                                as restatements,
        count(distinct restatements_model.cik)                  as restating_companies,
        count(*) filter (
            where restatements_model.revision_direction = 'decrease'
        )                                                       as downward_restatements,
        percentile_cont(0.5) within group (
            order by abs(restatements_model.pct_revision)
        )                                                       as median_abs_pct_revision
    from {{ ref('int_restatements') }} as restatements_model
    left join company_sector as sector
        on  sector.cik = restatements_model.cik
        and restatements_model.first_filed_date
                between sector.valid_from and sector.valid_to
    group by grouping sets (
        (sector.sic_division, sector.sic_major_group),
        (sector.sic_division),
        ()
    )

),

filings_by_sector as (

    -- The second denominator, at filing grain rather than fact grain. Each
    -- filing is attributed on its own filed_date, so this too is an as-at
    -- measure.
    select
        sector.sic_division,
        sector.sic_major_group,
        grouping(sector.sic_division, sector.sic_major_group)   as grouping_level,
        count(*)                                                as filings,
        count(distinct filings_dim.cik)                         as companies
    from {{ ref('dim_filing') }} as filings_dim
    left join company_sector as sector
        on  sector.cik = filings_dim.cik
        and filings_dim.filed_date between sector.valid_from and sector.valid_to
    group by grouping sets (
        (sector.sic_division, sector.sic_major_group),
        (sector.sic_division),
        ()
    )

),

combined as (

    -- The three aggregations share a grain, so they join on the grouping level
    -- plus the keys. is not distinct from, because at the rolled-up levels the
    -- grouping columns are null on both sides and = would drop every total row.
    select
        coalesce(restated.sic_division, 'All sectors')           as sic_division,
        restated.sic_major_group,
        restated.grouping_level,
        restated.restatements,
        restated.restating_companies,
        restated.downward_restatements,
        restated.median_abs_pct_revision,
        revisable.revisable_groups,
        filings.filings,
        filings.companies
    from restated_by_sector as restated
    left join revisable_by_sector as revisable
        on  revisable.grouping_level = restated.grouping_level
        and revisable.sic_division   is not distinct from restated.sic_division
        and revisable.sic_major_group is not distinct from restated.sic_major_group
    left join filings_by_sector as filings
        on  filings.grouping_level = restated.grouping_level
        and filings.sic_division   is not distinct from restated.sic_division
        and filings.sic_major_group is not distinct from restated.sic_major_group

)

select
    sic_division,
    sic_major_group,

    case grouping_level
        when 0 then 'major_group'
        when 1 then 'division'
        else 'grand_total'
    end                                                         as aggregation_level,

    restatements,
    revisable_groups,
    filings,
    companies,
    restating_companies,

    -- The defensible rate: restated share of facts that could have been
    -- revised. Bounded 0-1 and comparable across sectors of any size.
    round(100.0 * restatements / nullif(revisable_groups, 0), 3)
                                                                as pct_of_revisable_restated,

    -- The volume-normalised rate. Not a probability: one filing can restate
    -- many facts, so this runs well above 100 and is only ever read as a
    -- between-sector comparison.
    round(1.0 * restatements / nullif(filings, 0), 2)           as restatements_per_filing,

    round(100.0 * restating_companies / nullif(companies, 0), 2)
                                                                as pct_companies_restating,
    round(100.0 * downward_restatements / nullif(restatements, 0), 2)
                                                                as pct_restatements_downward,
    round(median_abs_pct_revision::numeric, 4)                  as median_abs_pct_revision

from combined
order by
    grouping_level desc,
    restatements desc
