{{ config(materialized='table') }}

/*
  One row per submission, keyed on adsh.

  Deliberately thin: staging already parses the dates, derives filing_lag_days
  and reads the amendment flags, so this model adds a surrogate key and the
  readable filer-status label and otherwise passes through. Recomputing any of
  it here would create a second definition of the same field.
*/

select
    {{ dbt_utils.generate_surrogate_key(['adsh']) }} as filing_sk,
    adsh,
    cik,
    form_type,

    -- SEC accelerated filer status (sub.afs). Only 1-LAF, 2-ACC and 4-NON
    -- occur in the loaded range; the other two are mapped for completeness.
    filer_status,
    case filer_status
        when '1-LAF' then 'large accelerated filer'
        when '2-ACC' then 'accelerated filer'
        when '3-SRA' then 'smaller reporting accelerated filer'
        when '4-NON' then 'non-accelerated filer'
        when '5-SML' then 'smaller reporting filer'
    end                                             as filer_status_name,

    fiscal_year,
    fiscal_period,
    period_end_date,
    filed_date,
    filing_lag_days,
    is_amendment,
    was_later_amended
from {{ ref('stg_submissions') }}
