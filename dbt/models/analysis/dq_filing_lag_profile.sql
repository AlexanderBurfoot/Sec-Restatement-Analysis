{{ config(materialized='table') }}

/*
  How long after a period ends do its numbers become public?

  This is the first genuinely interesting finding in the project: it quantifies
  the window during which anyone acting on "current" fundamentals is acting on
  data that does not exist yet.
*/
select
    form_type,
    filer_status,
    count(*)                                                as filings,
    round(avg(filing_lag_days))                             as mean_lag_days,
    percentile_cont(0.50) within group (order by filing_lag_days) as median_lag_days,
    percentile_cont(0.90) within group (order by filing_lag_days) as p90_lag_days,
    min(filing_lag_days)                                    as min_lag_days,
    max(filing_lag_days)                                    as max_lag_days
from {{ ref('stg_submissions') }}
where filing_lag_days between 0 and 1095
  and form_type in ('10-K', '10-Q', '10-K/A', '10-Q/A')
group by grouping sets ((form_type, filer_status), (form_type), ())
order by form_type nulls last, filer_status nulls last
