{{ config(materialized='table') }}

/*
  One row per data quality rule, with rows affected and rate. Every rule here
  was found by querying the data, not assumed in advance.

  Severity is honest: "high" means a downstream number would be wrong, not
  merely that the data is untidy.
*/

with total_facts as (
    select count(*)::numeric as n from {{ ref('stg_numeric') }}
),
total_filings as (
    select count(*)::numeric as n from {{ ref('stg_submissions') }}
),

null_values as (
    select
        'Null numeric value'    as rule_name,
        'completeness'          as dimension,
        'medium'                as severity,
        count(*)                as rows_affected,
        (select n from total_facts) as rows_checked
    from {{ ref('stg_numeric') }}
    where value is null
),

filed_before_period as (
    select
        'Filed before the period it reports', 'validity', 'high',
        count(*), (select n from total_filings)
    from {{ ref('stg_submissions') }}
    where filed_date < period_end_date
),

implausible_lag as (
    select
        'Filing lag exceeds three years', 'timeliness', 'medium',
        count(*), (select n from total_filings)
    from {{ ref('stg_submissions') }}
    where filing_lag_days > 1095
),

implausible_duration as (
    select
        'Reporting duration exceeds ten years', 'validity', 'high',
        count(*), (select n from total_facts)
    from {{ ref('stg_numeric') }}
    where qtrs > 40 or qtrs < 0
),

conflicting_duplicates as (
    -- The same fact reported twice within ONE filing, with different values.
    -- A consumer picking arbitrarily gets a different answer by row order.
    select
        'Duplicate key with conflicting values', 'consistency', 'high',
        coalesce(sum(occurrences), 0), (select n from total_facts)
    from (
        select count(*) as occurrences
        from {{ ref('stg_numeric') }}
        group by adsh, tag, taxonomy_version, coregistrant,
                 segments, period_end_date, qtrs, unit_of_measure
        having count(*) > 1 and count(distinct value) > 1
    ) d
),

rejected_at_load as (
    -- Rows discarded during ingestion: free-text fields containing literal tab
    -- characters produce more fields than the header declares, and the row
    -- cannot be repaired reliably.
    select
        'Rejected at load: embedded delimiter', 'validity', 'medium',
        coalesce(sum(rows_rejected), 0),
        (select n from total_facts) + coalesce(sum(rows_rejected), 0)
    from {{ source('raw', 'load_rejects') }}
),

unioned as (
    select * from null_values
    union all select * from filed_before_period
    union all select * from implausible_lag
    union all select * from implausible_duration
    union all select * from conflicting_duplicates
    union all select * from rejected_at_load
)

select
    rule_name,
    dimension,
    severity,
    rows_affected,
    rows_checked,
    round(100.0 * rows_affected / nullif(rows_checked, 0), 5) as pct_affected
from unioned
order by
    case severity when 'high' then 1 when 'medium' then 2 else 3 end,
    rows_affected desc
