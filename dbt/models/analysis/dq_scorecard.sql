{{ config(materialized='table') }}

/*
  The Stage 1 headline deliverable: one row per data quality rule, with the
  number of rows affected and the rate. This is the table that goes in the
  README, and it is the artefact that maps most directly onto data quality
  and controls roles.

  Add a rule by adding a CTE and a union branch. Keep severity honest --
  "high" should mean a number would be wrong, not merely untidy.
*/

with total_facts as (
    select count(*)::numeric as n from {{ ref('stg_numeric') }}
),
total_filings as (
    select count(*)::numeric as n from {{ ref('stg_submissions') }}
),

null_values as (
    select
        'Null numeric value' as rule_name,
        'completeness'       as dimension,
        'medium'             as severity,
        count(*)             as rows_affected,
        (select n from total_facts) as rows_checked
    from {{ ref('stg_numeric') }}
    where value is null
),

unparseable_dates as (
    select
        'Unparseable filing date', 'validity', 'high',
        count(*), (select n from total_filings)
    from {{ ref('stg_submissions') }}
    where filed_date is null
),

negative_lag as (
    select
        'Filed before period end', 'validity', 'high',
        count(*), (select n from total_filings)
    from {{ ref('stg_submissions') }}
    where filing_lag_days < 0
),

custom_tags as (
    select
        'Company-specific custom tag', 'comparability', 'medium',
        count(*), (select n from total_facts)
    from {{ ref('stg_numeric') }}
    where is_custom_tag
),

orphan_facts as (
    select
        'Numeric fact with no filing', 'integrity', 'high',
        count(*), (select n from total_facts)
    from {{ ref('stg_numeric') }} n
    where not exists (
        select 1 from {{ ref('stg_submissions') }} s where s.adsh = n.adsh
    )
),

unioned as (
    select * from null_values
    union all select * from unparseable_dates
    union all select * from negative_lag
    union all select * from custom_tags
    union all select * from orphan_facts
)

select
    rule_name,
    dimension,
    severity,
    rows_affected,
    rows_checked,
    round(100.0 * rows_affected / nullif(rows_checked, 0), 3) as pct_affected
from unioned
order by
    case severity when 'high' then 1 when 'medium' then 2 else 3 end,
    rows_affected desc
