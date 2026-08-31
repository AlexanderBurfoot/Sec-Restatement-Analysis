{{
    config(
        materialized='table',
        indexes=[{'columns': ['adsh'], 'type': 'btree'}]
    )
}}

/*
  The same five features over the same filings and the same label, computed the
  way they are computed when nobody is watching the clock: one pass over the
  whole loaded range, every filing aggregated with every other regardless of
  when it was filed or when its revision surfaced.

  Four things leak, across the two features, in increasing order of what they
  turn out to be worth:

  - The sector is read from the dim_company version current today, joined on
    is_current rather than range-joined on filed_date, so a company that
    reclassified is scored against peers it had not yet joined. 1,330 filings by
    268 companies sit in different SIC major groups under the two readings.
  - The sector rate spans every filing in the range, including filings made
    after this one.
  - It also includes the filing being scored, so on the smallest SIC major
    groups a filing is a visible fraction of its own feature.
  - prior_restatement_count counts every one of the company's revised filings
    across the range, the scored filing included. On the test split its median
    is 7 for restated filings against 4 for clean ones. It is less a feature
    than a smeared copy of the answer, and it carries almost all of the measured
    gap on its own.

  How much of this a working modeller would actually write is hypothesised and
  was not surveyed. Two of the four are the path of least resistance: is_current
  is the easy join and a whole-window group by is the easy aggregate. The
  prior_restatement_count construction is harder to defend that way, because the
  identifier says "prior" and the code does not — and that is the one carrying
  the effect. Read the gap as what these two constructions are worth, not as a
  general price for leakage.

  Nor is a missing date predicate the whole of the difference, though it is the
  largest part of it. Adding `filed_date <` the scored filing's date to the
  sector rate would fix the second and third of these and still be wrong: it
  would put filings still inside their own observation window into the
  denominator as clean ones. feat_filing_pit dates each contribution at
  filed_date + horizon for exactly that reason. The point-in-time table is a
  different construction, not this one with a where clause.

  filing_lag_days, filer status and custom_tag_share are properties of the
  filing as published and are read unchanged from feat_filing_base. They are the
  control: whatever accuracy survives on point-in-time features is mostly
  theirs, and the gap between the two models is what the other two features
  were borrowing from the future.
*/

with base as (

    select * from {{ ref('feat_filing_base') }}

),

sector_rate as (

    -- No date predicate, and no exclusion of the row being scored. On the
    -- smallest SIC major groups the filing is a visible fraction of its own
    -- feature.
    select
        sic_major_group_now                                     as sic_major_group,
        count(*)                                                as n_filings,
        count(*) filter (where was_restated)                    as n_restated,
        count(*) filter (where was_restated)::numeric
            / count(*)                                          as restatement_rate
    from base
    where sic_major_group_now is not null
    group by sic_major_group_now

),

market_rate as (

    -- The fallback for filings whose current SIC is not a four-digit code, so
    -- that the two models fall back on the same shape of quantity and the gap
    -- between them is not partly a difference in how missing sectors are
    -- handled.
    select
        count(*)                                                as n_filings,
        count(*) filter (where was_restated)::numeric
            / count(*)                                          as restatement_rate
    from base

),

prior_restatements as (

    -- "Prior" only in name. This counts the company's revised filings across
    -- the whole range, the filing being scored included, so a filing whose own
    -- revision is what made the count non-zero reads its own label back.
    select
        cik,
        count(*) filter (where revision_first_seen_date is not null)
                                                                as restated_filing_count
    from base
    group by cik

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

    prior_restatements.restated_filing_count                    as prior_restatement_count,
    coalesce(sector_rate.restatement_rate, market_rate.restatement_rate)
                                                                as sector_restatement_rate,

    base.sic_major_group_now                                    as sic_major_group,
    coalesce(sector_rate.n_filings, 0)                          as sector_prior_resolved_filings,
    market_rate.n_filings                                       as market_prior_resolved_filings
from base
cross join market_rate
left join sector_rate
    on sector_rate.sic_major_group = base.sic_major_group_now
left join prior_restatements
    on prior_restatements.cik = base.cik
