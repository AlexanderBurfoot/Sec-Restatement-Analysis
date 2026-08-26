-- A filing cannot be published before the period it reports on. Any row here is
-- a genuine source data defect, and the count is a finding for the DQ scorecard.
select
    adsh,
    company_name,
    period_end_date,
    filed_date,
    filing_lag_days
from {{ ref('stg_submissions') }}
where filed_date is not null
  and period_end_date is not null
  and filed_date < period_end_date
