{{ config(materialized='table') }}

{% set calendar_start_date = "date '2009-01-01'" %}
{% set calendar_end_date   = "date '2027-12-31'" %}
{% set australian_fiscal_year_start_month = 7 %}
{% set last_weekday_isodow = 5 %}

/*
  Generated calendar covering the filing dates and period end dates in the
  loaded range with room either side, so date joins never drop a row for want of
  a dimension entry.

  The Australian fiscal year runs July-June and is labelled by the calendar year
  in which it ends: 2023-07-01 through 2024-06-30 is fiscal 2024. This is the
  reporting convention the analysis is written for; SEC fiscal periods stay on
  the filing's own fiscal_year and fiscal_period in dim_filing.
*/

with date_spine as (

    select generated_date::date as date_day
    from generate_series(
        {{ calendar_start_date }},
        {{ calendar_end_date }},
        interval '1 day'
    ) as generated_date

)

select
    to_char(date_day, 'YYYYMMDD')::int          as date_sk,
    date_day,
    extract(year    from date_day)::int         as calendar_year,
    extract(quarter from date_day)::int         as calendar_quarter,
    extract(month   from date_day)::int         as calendar_month,
    extract(week    from date_day)::int         as iso_week,

    -- ISO day of week: 1 = Monday through 7 = Sunday.
    extract(isodow  from date_day)::int         as day_of_week,
    (extract(isodow from date_day) <= {{ last_weekday_isodow }})
                                                as is_weekday,
    date_trunc('month', date_day)::date         as month_start_date,
    (date_trunc('month', date_day)
        + interval '1 month' - interval '1 day')::date
                                                as month_end_date,

    case
        when extract(month from date_day)
                >= {{ australian_fiscal_year_start_month }}
            then extract(year from date_day)::int + 1
        else extract(year from date_day)::int
    end                                         as australian_fiscal_year
from date_spine
