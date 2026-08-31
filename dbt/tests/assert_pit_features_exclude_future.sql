-- The claim feat_filing_pit makes is that neither of its two historical features
-- reads anything published on or after the filing date. Both are computed by a
-- running sum over a sorted union of query rows and event rows, which is fast
-- but is not obviously correct by inspection: the strictly-prior semantics rest
-- entirely on query rows sorting before same-day events.
--
-- So both are recomputed here the slow, obvious way — a range join with the date
-- predicate written out — and compared. The recomputation is done once per
-- distinct query point rather than once per filing, which is what keeps an exact
-- check over 58,726 rows from becoming a quadratic scan.
--
-- Returns one row per filing whose feature disagrees with the recomputation.

{% set label_horizon_days = var('restatement_label_horizon_days') %}

with base as (

    select * from {{ ref('feat_filing_base') }}

),

sector_query_points as (

    select distinct
        sic_major_group_at_filing   as sic_major_group,
        filed_date
    from base
    where sic_major_group_at_filing is not null

),

expected_sector_history as (

    -- A filing's own outcome joins the sector rate only once its observation
    -- window has closed, which is the horizon after it was filed.
    select
        sector_query_points.sic_major_group,
        sector_query_points.filed_date,
        count(base.adsh)                                    as n_resolved,
        count(base.adsh) filter (where base.was_restated)   as n_restated
    from sector_query_points
    left join base
        on  base.sic_major_group_at_filing = sector_query_points.sic_major_group
        and base.filed_date + {{ label_horizon_days }} < sector_query_points.filed_date
    group by sector_query_points.sic_major_group, sector_query_points.filed_date

),

company_query_points as (

    select distinct
        cik,
        filed_date
    from base

),

expected_prior_restatements as (

    -- No horizon here: a revision was knowable the day it was published,
    -- whether or not it arrived in time to have set the label.
    select
        company_query_points.cik,
        company_query_points.filed_date,
        count(base.adsh)                                    as n_prior_restatements
    from company_query_points
    left join base
        on  base.cik = company_query_points.cik
        and base.revision_first_seen_date < company_query_points.filed_date
    group by company_query_points.cik, company_query_points.filed_date

),

compared as (

    select
        pit.adsh,
        pit.sector_prior_resolved_filings,
        expected_sector_history.n_resolved                  as expected_resolved,
        pit.prior_restatement_count,
        expected_prior_restatements.n_prior_restatements    as expected_prior_restatements
    from {{ ref('feat_filing_pit') }} as pit
    join base
        on base.adsh = pit.adsh
    join expected_prior_restatements
        on  expected_prior_restatements.cik = base.cik
        and expected_prior_restatements.filed_date = base.filed_date
    left join expected_sector_history
        on  expected_sector_history.sic_major_group = base.sic_major_group_at_filing
        and expected_sector_history.filed_date = base.filed_date

)

select *
from compared
where prior_restatement_count is distinct from expected_prior_restatements
   or sector_prior_resolved_filings
        is distinct from coalesce(expected_resolved, 0)
