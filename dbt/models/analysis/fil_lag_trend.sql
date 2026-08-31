{{ config(materialized='table') }}

{% set max_plausible_lag_days = 1095 %}
{% set trailing_window_quarters = 4 %}
{% set seasonal_lag_quarters = 4 %}

/*
  Has the wait for a number to become public moved over the loaded range?

  Aggregated by filing quarter, not by period quarter, and the choice is not
  cosmetic. The load is organised by filing quarter, so 2023Q1 through 2025Q4
  are twelve complete quarters on that axis. On a period axis the recent end is
  censored: a period ending 2025-12-31 is filed in 2026 and is almost entirely
  absent, so the last quarters would show a spuriously short lag drawn from the
  early filers alone.

  What remains is seasonality, and it is large. The 10-Ks filed in Q1 are
  calendar-year filers near their deadline; the 10-Ks filed in Q3 are
  off-calendar filers and late ones. Comparing adjacent quarters therefore
  measures the calendar, not behaviour. Both comparisons here span a full
  seasonal cycle for that reason: a trailing four-quarter mean and the same
  quarter one year earlier.

  Twelve points per series is a short series. The slope is reported with the
  r-squared of the same fit and the residual spread beside it, so the reader can
  see how much of the movement the trend actually accounts for. It is a
  description of the loaded range, not an estimate of a rate of change that
  would hold outside it.
*/

with quarterly_lag as (

    -- Series are split by filer status as well as form. The status mix shifts
    -- across quarters, and since the three statuses sit roughly thirty days
    -- apart, a pooled series would read a change in who filed as a change in
    -- how fast anyone filed.
    select
        form_type,
        filer_status,
        date_trunc('quarter', filed_date)::date         as filed_quarter,
        count(*)                                        as filings,
        round(avg(filing_lag_days))                     as mean_lag_days,
        percentile_cont(0.50) within group (order by filing_lag_days)
                                                        as median_lag_days,
        percentile_cont(0.90) within group (order by filing_lag_days)
                                                        as p90_lag_days
    from {{ ref('dim_filing') }}
    where form_type in ('10-K', '10-Q')
      and filer_status is not null
      and filing_lag_days between 0 and {{ max_plausible_lag_days }}
    group by 1, 2, 3

),

sequenced as (

    select
        quarterly_lag.*,
        row_number() over series_by_quarter              as quarter_index,
        count(*)      over series                        as n_quarters_in_series
    from quarterly_lag
    window
        series           as (partition by form_type, filer_status),
        series_by_quarter as (partition by form_type, filer_status order by filed_quarter)

),

compared as (

    select
        sequenced.*,

        -- A full seasonal cycle of history, excluding the current quarter, so
        -- the quarter is compared against a like-for-like mix and not against
        -- itself.
        avg(median_lag_days) over trailing_cycle         as trailing_mean_median_lag_days,
        count(*)             over trailing_cycle         as trailing_quarters_available,

        lag(median_lag_days, {{ seasonal_lag_quarters }}) over series_by_quarter
                                                        as median_lag_days_same_quarter_last_year,

        -- Fitted over the whole series at once. quarter_index is the regressor,
        -- so the slope is days of lag per quarter.
        regr_slope(median_lag_days, quarter_index) over series
                                                        as slope_days_per_quarter,
        regr_r2(median_lag_days, quarter_index) over series
                                                        as trend_r_squared,
        stddev_samp(median_lag_days) over series         as series_stddev_days

    from sequenced
    window
        series            as (partition by form_type, filer_status),
        series_by_quarter as (partition by form_type, filer_status order by filed_quarter),
        trailing_cycle    as (
            partition by form_type, filer_status
            order by filed_quarter
            rows between {{ trailing_window_quarters }} preceding and 1 preceding
        )

)

select
    form_type,
    filer_status,
    filed_quarter,
    quarter_index,
    n_quarters_in_series,
    filings,

    mean_lag_days,
    median_lag_days,
    p90_lag_days,

    round(trailing_mean_median_lag_days::numeric, 1)    as trailing_mean_median_lag_days,
    round((median_lag_days - trailing_mean_median_lag_days)::numeric, 1)
                                                        as delta_vs_trailing_mean_days,
    median_lag_days_same_quarter_last_year,
    median_lag_days - median_lag_days_same_quarter_last_year
                                                        as delta_vs_same_quarter_last_year,

    -- The trend, and immediately beside it what it is worth. r-squared is the
    -- share of the quarter-to-quarter movement the straight line explains; the
    -- rest is seasonality and noise that twelve points cannot separate.
    round(slope_days_per_quarter::numeric, 3)           as slope_days_per_quarter,
    round((slope_days_per_quarter * 4)::numeric, 2)     as trend_days_per_year,
    round(trend_r_squared::numeric, 3)                  as trend_r_squared,
    round(series_stddev_days::numeric, 2)               as series_stddev_days,

    -- The trailing comparison is undefined until a full cycle has accrued.
    -- Flagged rather than filtered, so the early quarters keep their own
    -- medians and only the derived comparison is marked incomplete.
    (trailing_quarters_available = {{ trailing_window_quarters }})
                                                        as has_full_trailing_window,

    -- A judgement call, declared: a straight line through twelve seasonal
    -- points is treated as describing the series only where it accounts for
    -- most of the variation. Below that the slope is reported and should not
    -- be read as a trend.
    case
        when trend_r_squared >= 0.5 and slope_days_per_quarter > 0 then 'slower'
        when trend_r_squared >= 0.5 and slope_days_per_quarter < 0 then 'faster'
        else 'no trend distinguishable from seasonality'
    end                                                 as trend_reading

from compared
order by form_type, filer_status, filed_quarter
