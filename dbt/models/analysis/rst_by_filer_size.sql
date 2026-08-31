{{
    config(
        materialized='table',
        pre_hook="set work_mem = '512MB'"
    )
}}

/*
  Does the restatement rate grade by filer size?

  Two size measures, stacked in one table because they disagree and the
  disagreement is the finding. The regulatory bands (sub.afs, a public-float
  threshold) grade monotonically: smaller filers restate more. Deciles of total
  assets do not, the rate falls from the second decile to the ninth and then
  turns back up at the largest. The regulatory cut cannot show that, because a
  single band spans the whole of the reversal: 1-LAF is 45% of the seventh
  decile and 85% of the tenth, so the fall and the rise are averaged together
  inside one row.

  The segment and sector splits are carried as columns rather than as separate
  models so the reversal can be read off a single row. They are the two controls
  that were run against it: large filers report a far higher share of
  segment-level facts, and skew financial, so either could have produced the
  uptick as a composition effect. Neither does, the shape survives inside both
  splits, but the uptick is concentrated in large financials, which is a
  hypothesis about where it lives, not a tested cause.

  Size is measured from each company's most recent reported period, not as-at
  the fact. A company is therefore in one decile for the whole loaded range,
  and one that grew or shrank across 2023-2025 is banded on where it ended.
  This is the one attribution in the restatement models that is not as-at, and
  it is a deliberate trade: an as-at size would reband a company mid-series and
  make a decile mean something different at each end of the window. The sector
  and filer-status attributions below remain as-at.
*/

{% set assets_tag = 'Assets' %}
{% set assets_unit = 'USD' %}
{% set assets_qtrs = 0 %}
{% set n_size_deciles = 10 %}
{% set financial_sic_low = 6000 %}
{% set financial_sic_high = 6799 %}
{% set unbanded_sort = 99 %}

with company_size as (

    -- Consolidated total assets, in USD, from the latest period the company
    -- reported, at the value first published for that period. Consolidated
    -- means segments and coregistrant both empty: a segment's assets or a
    -- subsidiary's are not the filer's size. Neither column is ever null in
    -- fct_financial_fact, so = '' is exact here.
    --
    -- Non-USD reporters are excluded rather than converted. The warehouse holds
    -- no FX rates, and ranking a KRW balance sheet against a USD one would put
    -- every won-denominated filer in the top decile.
    select
        cik,
        total_assets,
        ntile({{ n_size_deciles }}) over (order by total_assets)     as assets_decile
    from (
        select
            cik,
            value                                                   as total_assets,
            row_number() over (
                partition by cik
                order by period_end_date desc, filed_date asc, value desc
            )                                                       as recency_rank
        from {{ ref('fct_financial_fact') }}
        where tag             = '{{ assets_tag }}'
          and unit_of_measure = '{{ assets_unit }}'
          and qtrs            = {{ assets_qtrs }}
          and segments        = ''
          and coregistrant    = ''
          and value is not null
          and value > 0
    ) as latest_assets
    where recency_rank = 1

),

decile_bounds as (

    select
        assets_decile,
        min(total_assets)                                           as min_total_assets,
        percentile_cont(0.5) within group (order by total_assets)   as median_total_assets
    from company_size
    group by assets_decile

),

company_sector as (

    -- Financial versus everything else, on the same 6000-6799 boundary
    -- rst_by_sector uses for its Finance, Insurance & Real Estate division, so
    -- the two models cannot disagree about what a financial company is.
    -- Effective-dated, and joined below on the date the fact was first
    -- published.
    select
        cik,
        valid_from,
        valid_to,
        case
            when sic_code ~ '^[0-9]{4}$'
             and sic_code::int between {{ financial_sic_low }} and {{ financial_sic_high }}
                then 'financial'
            else 'non-financial'
        end                                                         as sector_group
    from {{ ref('dim_company') }}

),

revisable_groups as (

    -- The denominator: described facts reported on more than one date, and so
    -- capable of being revised. Same population and same key int_restatements
    -- filters down from.
    --
    -- first_adsh resolves ties the way int_restatements does, the highest
    -- accession issued on the earliest filing date. Numerator and denominator
    -- have to pick the same filing or a company that changed filer status
    -- mid-range would have its facts counted under one band and its
    -- restatements under another.
    select
        cik,
        (segments <> '')                                            as is_segment,
        min(filed_date)                                             as first_filed_date,
        (array_agg(adsh order by filed_date, adsh desc))[1]         as first_adsh
    from {{ ref('fct_financial_fact') }}
    where value is not null
    group by cik, coregistrant, segments, tag, period_end_date, qtrs, unit_of_measure
    having count(distinct filed_date) > 1

),

revisable_attributed as (

    select
        revisable.cik,
        revisable.is_segment,
        filing.filer_status,
        filing.filer_status_name,
        sector.sector_group,
        size.assets_decile
    from revisable_groups as revisable
    left join {{ ref('dim_filing') }} as filing
        on filing.adsh = revisable.first_adsh
    left join company_sector as sector
        on  sector.cik = revisable.cik
        and revisable.first_filed_date between sector.valid_from and sector.valid_to
    left join company_size as size
        on size.cik = revisable.cik

),

restated_attributed as (

    -- The numerator, attributed by the identical three rules. int_restatements
    -- already carries first_adsh and first_filed_date, so nothing is recomputed
    -- from the fact table here.
    select
        restatements.cik,
        (restatements.segments <> '')                               as is_segment,
        abs(restatements.pct_revision)                              as abs_pct_revision,
        filing.filer_status,
        sector.sector_group,
        size.assets_decile
    from {{ ref('int_restatements') }} as restatements
    left join {{ ref('dim_filing') }} as filing
        on filing.adsh = restatements.first_adsh
    left join company_sector as sector
        on  sector.cik = restatements.cik
        and restatements.first_filed_date between sector.valid_from and sector.valid_to
    left join company_size as size
        on size.cik = restatements.cik

),

revisable_banded as (

    -- The two size measures are stacked rather than joined side by side. They
    -- band different things, a filing's filer status, a company's assets, and
    -- have different populations, so they cannot share a row.
    select
        'filer_status'                                              as size_basis,
        coalesce(filer_status, 'unknown')                           as size_band,
        coalesce(filer_status_name, 'filer status not reported')    as size_band_label,
        coalesce(nullif(left(filer_status, 1), '')::int, {{ unbanded_sort }})
                                                                    as band_sort,
        null::int                                                   as assets_decile,
        cik,
        is_segment,
        sector_group
    from revisable_attributed

    union all

    select
        'assets_decile',
        coalesce(lpad(assets_decile::text, 2, '0'), 'unclassified'),
        case
            when assets_decile = 1                     then 'decile 1 (smallest)'
            when assets_decile = {{ n_size_deciles }}  then 'decile {{ n_size_deciles }} (largest)'
            when assets_decile is null                 then 'no consolidated USD assets reported'
            else 'decile ' || assets_decile::text
        end,
        coalesce(assets_decile, {{ unbanded_sort }}),
        assets_decile,
        cik,
        is_segment,
        sector_group
    from revisable_attributed

),

restated_banded as (

    select
        'filer_status'                                              as size_basis,
        coalesce(filer_status, 'unknown')                           as size_band,
        cik,
        is_segment,
        sector_group,
        abs_pct_revision
    from restated_attributed

    union all

    select
        'assets_decile',
        coalesce(lpad(assets_decile::text, 2, '0'), 'unclassified'),
        cik,
        is_segment,
        sector_group,
        abs_pct_revision
    from restated_attributed

),

revisable_by_band as (

    select
        size_basis,
        size_band,
        min(size_band_label)                                        as size_band_label,
        min(band_sort)                                              as band_sort,
        min(assets_decile)                                          as assets_decile,
        count(distinct cik)                                         as companies,
        count(*)                                                    as revisable_groups,
        count(*) filter (where not is_segment)                      as revisable_groups_consolidated,
        count(*) filter (where is_segment)                          as revisable_groups_segment,
        count(*) filter (where sector_group = 'financial')          as revisable_groups_financial,
        count(*) filter (where sector_group = 'non-financial')      as revisable_groups_non_financial
    from revisable_banded
    group by size_basis, size_band

),

restated_by_band as (

    select
        size_basis,
        size_band,
        count(distinct cik)                                         as restating_companies,
        count(*)                                                    as restatements,
        count(*) filter (where not is_segment)                      as restatements_consolidated,
        count(*) filter (where is_segment)                          as restatements_segment,
        count(*) filter (where sector_group = 'financial')          as restatements_financial,
        count(*) filter (where sector_group = 'non-financial')      as restatements_non_financial,
        percentile_cont(0.5) within group (order by abs_pct_revision)
                                                                    as median_abs_pct_revision
    from restated_banded
    group by size_basis, size_band

)

select
    revisable.size_basis,
    revisable.size_band,
    revisable.size_band_label,
    revisable.band_sort,

    -- Populated on the assets_decile rows only; a filer status band has no
    -- asset range because it is not defined by one.
    bounds.min_total_assets,
    bounds.median_total_assets,

    revisable.companies,
    coalesce(restated.restating_companies, 0)                       as restating_companies,
    round(100.0 * coalesce(restated.restating_companies, 0)
          / nullif(revisable.companies, 0), 2)                      as pct_companies_restating,

    revisable.revisable_groups,
    coalesce(restated.restatements, 0)                              as restatements,
    round(100.0 * coalesce(restated.restatements, 0)
          / nullif(revisable.revisable_groups, 0), 3)               as pct_of_revisable_restated,
    round(restated.median_abs_pct_revision::numeric, 4)             as median_abs_pct_revision,

    -- Control one: the segment split. Large filers report proportionally more
    -- segment-level facts, so a rate computed over the pooled population could
    -- move with nothing but that mix. pct_segment_level is the mix itself.
    revisable.revisable_groups_consolidated,
    coalesce(restated.restatements_consolidated, 0)                 as restatements_consolidated,
    round(100.0 * coalesce(restated.restatements_consolidated, 0)
          / nullif(revisable.revisable_groups_consolidated, 0), 3)  as pct_restated_consolidated,

    revisable.revisable_groups_segment,
    coalesce(restated.restatements_segment, 0)                      as restatements_segment,
    round(100.0 * coalesce(restated.restatements_segment, 0)
          / nullif(revisable.revisable_groups_segment, 0), 3)       as pct_restated_segment,

    round(100.0 * revisable.revisable_groups_segment
          / nullif(revisable.revisable_groups, 0), 1)               as pct_segment_level,

    -- Control two: the sector split, on the same reasoning. Financials are a
    -- rising share of the population as size rises.
    revisable.revisable_groups_financial,
    coalesce(restated.restatements_financial, 0)                    as restatements_financial,
    round(100.0 * coalesce(restated.restatements_financial, 0)
          / nullif(revisable.revisable_groups_financial, 0), 3)     as pct_restated_financial,

    revisable.revisable_groups_non_financial,
    coalesce(restated.restatements_non_financial, 0)                as restatements_non_financial,
    round(100.0 * coalesce(restated.restatements_non_financial, 0)
          / nullif(revisable.revisable_groups_non_financial, 0), 3) as pct_restated_non_financial,

    round(100.0 * revisable.revisable_groups_financial
          / nullif(revisable.revisable_groups, 0), 1)               as pct_financial

from revisable_by_band as revisable

-- Left joined: a band with no restatements at all is still a row, and reads as
-- a zero rather than vanishing from the table.
left join restated_by_band as restated
    on  restated.size_basis = revisable.size_basis
    and restated.size_band  = revisable.size_band

-- Joined on the decile number carried through the union, not on size_band
-- parsed back to an integer: size_band also holds 'unknown' and 'unclassified',
-- and the cast is evaluated before the size_basis predicate can exclude them.
left join decile_bounds as bounds
    on bounds.assets_decile = revisable.assets_decile

order by
    revisable.size_basis,
    revisable.band_sort
