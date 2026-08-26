-- Lags beyond three years indicate a mis-parsed date or a delinquent filer
-- catching up on old periods. Both are worth surfacing rather than silently
-- carrying into the analysis.
select adsh, company_name, period_end_date, filed_date, filing_lag_days
from {{ ref('stg_submissions') }}
where filing_lag_days > 1095
