{{ config(materialized='table') }}

{% set max_plausible_lag_days = 1095 %}

/*
  Two different waits, on one row.

  dq_filing_lag_profile already measures the wait from period end to first
  publication, so this model joins to it rather than restating that definition;
  the lag columns below are Stage 1's numbers carried through, not a second
  computation of them. What is new is the second wait: when a filing is later
  amended, how long the market held the superseded number before the revision
  arrived. That gap is what makes a restatement expensive, and it is invisible
  in a profile that only measures each filing against its own period.

  Grain is (form_type, filer_status) with both non-null. The grouping-set
  subtotal rows in dq_filing_lag_profile carry a null form_type or filer_status
  that is indistinguishable from the 758 filings whose afs is genuinely blank,
  so joining to them would be ambiguous; totals are left where they already are.
*/

with lag_profile as (

    -- The form set is read from the upstream model rather than declared again,
    -- so the two stay in scope with each other by construction.
    select
        form_type,
        filer_status,
        filings,
        mean_lag_days,
        median_lag_days,
        p90_lag_days,
        min_lag_days,
        max_lag_days
    from {{ ref('dq_filing_lag_profile') }}
    where form_type is not null
      and filer_status is not null

),

reporting_filings as (

    select
        adsh,
        cik,
        form_type,
        replace(form_type, '/A', '')                    as base_form_type,
        filer_status,
        filer_status_name,
        period_end_date,
        filed_date,
        filing_lag_days,
        is_amendment,
        was_later_amended
    from {{ ref('dim_filing') }}
    where form_type in (select form_type from lag_profile)
      and filer_status is not null
      and period_end_date is not null
      -- The same plausibility bound dq_filing_lag_profile applies, so the
      -- amendment gap is measured over the same filings as the lag beside it.
      and filing_lag_days between 0 and {{ max_plausible_lag_days }}

),

amendment_to_original as (

    -- Each amendment is matched to the last original of the same base form for
    -- the same company and period published on or before it. An amendment of an
    -- amendment is therefore measured from the original, which is the wait that
    -- matters: how long the first published number stood.
    --
    -- Originals filed before 2023-01-03 are outside the loaded range, so an
    -- amendment of an older filing has nothing to match and is counted in
    -- n_amendments but not in n_matched_to_original. The two counts are both
    -- reported for that reason.
    select
        amendment.adsh                                  as amendment_adsh,
        amendment.form_type,
        amendment.filer_status,
        amendment.filed_date                            as amendment_filed_date,
        original.adsh                                   as original_adsh,
        original.filed_date                             as original_filed_date,
        amendment.filed_date - original.filed_date      as days_original_to_amendment
    from reporting_filings as amendment
    left join lateral (
        select
            candidate.adsh,
            candidate.filed_date
        from reporting_filings as candidate
        where candidate.cik = amendment.cik
          and candidate.base_form_type = amendment.base_form_type
          and candidate.period_end_date = amendment.period_end_date
          and not candidate.is_amendment
          and candidate.filed_date <= amendment.filed_date
        order by candidate.filed_date desc, candidate.adsh
        limit 1
    ) as original on true
    where amendment.is_amendment

),

amendment_gap as (

    select
        form_type,
        filer_status,
        count(*)                                        as n_amendments,
        count(original_adsh)                            as n_matched_to_original,
        percentile_cont(0.50) within group (order by days_original_to_amendment)
                                                        as median_days_original_to_amendment,
        percentile_cont(0.90) within group (order by days_original_to_amendment)
                                                        as p90_days_original_to_amendment,
        min(days_original_to_amendment)                 as min_days_original_to_amendment,
        max(days_original_to_amendment)                 as max_days_original_to_amendment
    from amendment_to_original
    group by form_type, filer_status

),

observed_amendments_per_original as (

    -- The other side of the same pairing, attributed to the original's own
    -- form and filer status.
    select distinct
        original_adsh
    from amendment_to_original
    where original_adsh is not null

),

original_outcome as (

    -- Two counts of the same thing that do not agree, and the disagreement is
    -- informative. was_later_amended is the filer's own prevrpt flag; the
    -- observed count is an amendment actually present in the loaded range. An
    -- original flagged as amended whose amendment lands after 2025-12-31 shows
    -- up in the first and not the second.
    select
        originals.form_type,
        originals.filer_status,
        count(*)                                        as n_originals,
        count(*) filter (where originals.was_later_amended)
                                                        as n_flagged_later_amended,
        count(observed.original_adsh)                   as n_observed_amended
    from reporting_filings as originals
    left join observed_amendments_per_original as observed
        on observed.original_adsh = originals.adsh
    where not originals.is_amendment
    group by originals.form_type, originals.filer_status

),

status_labels as (

    select distinct
        filer_status,
        filer_status_name
    from reporting_filings

)

select
    lag_profile.form_type,
    replace(lag_profile.form_type, '/A', '')            as base_form_type,
    (lag_profile.form_type like '%/A')                  as is_amendment_form,
    lag_profile.filer_status,
    status_labels.filer_status_name,

    -- Period end to publication. Carried from dq_filing_lag_profile unchanged.
    lag_profile.filings,
    lag_profile.mean_lag_days,
    lag_profile.median_lag_days,
    lag_profile.p90_lag_days,
    lag_profile.min_lag_days,
    lag_profile.max_lag_days,

    -- Original to its own amendment. Populated on amendment rows only.
    amendment_gap.n_amendments,
    amendment_gap.n_matched_to_original,
    round(amendment_gap.median_days_original_to_amendment)
                                                        as median_days_original_to_amendment,
    round(amendment_gap.p90_days_original_to_amendment)
                                                        as p90_days_original_to_amendment,
    amendment_gap.min_days_original_to_amendment,
    amendment_gap.max_days_original_to_amendment,

    -- How often the form gets amended at all. Populated on original rows only.
    original_outcome.n_originals,
    original_outcome.n_flagged_later_amended,
    original_outcome.n_observed_amended,
    round(100.0 * original_outcome.n_flagged_later_amended
          / nullif(original_outcome.n_originals, 0), 2)
                                                        as pct_flagged_later_amended,
    round(100.0 * original_outcome.n_observed_amended
          / nullif(original_outcome.n_originals, 0), 2)
                                                        as pct_observed_amended
from lag_profile

left join status_labels
    on status_labels.filer_status = lag_profile.filer_status

left join amendment_gap
    on  amendment_gap.form_type = lag_profile.form_type
    and amendment_gap.filer_status = lag_profile.filer_status

left join original_outcome
    on  original_outcome.form_type = lag_profile.form_type
    and original_outcome.filer_status = lag_profile.filer_status

order by base_form_type, is_amendment_form, filer_status
