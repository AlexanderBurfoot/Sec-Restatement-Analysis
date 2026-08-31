{{ config(materialized='table') }}

/*
  Which filers work to the deadline, and which ones do it habitually?

  A lag in days is not comparable across filers, because the deadline is not.
  A large accelerated filer's 10-K is due in 60 days and a non-accelerated
  filer's in 90, so the same 75-day lag is fifteen days late for one and fifteen
  days early for the other. Every filing here is measured against its own
  statutory due date instead, which puts all three statuses on one axis.

  Count alone still cannot separate a company that habitually files at the wire
  from one that had two bad quarters, so runs of consecutive deadline filings
  are found by gap and island over the company's own filing sequence.
*/

-- SEC periodic report deadlines, in calendar days after period end
-- (17 CFR 240.13a-1 and 13a-13). Smaller reporting companies that are not
-- accelerated file on the non-accelerated schedule.
{% set annual_deadline_days_large_accelerated = 60 %}
{% set annual_deadline_days_accelerated       = 75 %}
{% set annual_deadline_days_non_accelerated   = 90 %}
{% set quarterly_deadline_days_accelerated    = 40 %}
{% set quarterly_deadline_days_non_accelerated = 45 %}

{% set saturday_isodow = 6 %}
{% set sunday_isodow   = 7 %}

-- A filing landing within this many days of its due date is treated as filed
-- to the deadline rather than early. Derived from the observed distribution of
-- margins, not chosen: filings land on the due date itself at 20.1% of the
-- -3..+14 day window and on the following day at 10.8%, against a flat plateau
-- of roughly 7% per day from day 2 through day 7. The spike is the signature of
-- deadline-driven filing; the plateau is background. A wider bound was tried
-- first and rejected, at five days the flag captured 60% of all filings and
-- 65% of companies read as habitual, because the bound sat above the median
-- margin of four days and admitted the whole plateau.
{% set deadline_margin_days = 1 %}

{% set consecutive_run_min_length = 3 %}
{% set min_filings_for_ranking = 4 %}
{% set ntile_buckets = 10 %}
{% set max_plausible_lag_days = 1095 %}

with periodic_filings as (

    -- Originals only. An amendment has no deadline of its own, and including
    -- one would put a second filing for a period the company already met into
    -- the same sequence the runs are counted over.
    select
        adsh,
        cik,
        form_type,
        filer_status,
        filer_status_name,
        period_end_date,
        filed_date,
        filing_lag_days,

        case
            when form_type = '10-K' then
                case filer_status
                    when '1-LAF' then {{ annual_deadline_days_large_accelerated }}
                    when '2-ACC' then {{ annual_deadline_days_accelerated }}
                    else {{ annual_deadline_days_non_accelerated }}
                end
            else
                case filer_status
                    when '1-LAF' then {{ quarterly_deadline_days_accelerated }}
                    when '2-ACC' then {{ quarterly_deadline_days_accelerated }}
                    else {{ quarterly_deadline_days_non_accelerated }}
                end
        end                                             as statutory_days

    from {{ ref('dim_filing') }}
    where form_type in ('10-K', '10-Q')
      and filer_status is not null
      and period_end_date is not null
      and filed_date is not null
      and filing_lag_days between 0 and {{ max_plausible_lag_days }}

),

due_dates as (

    -- Rule 0-3(a): a due date falling on a weekend rolls to the next business
    -- day. Federal holidays are not modelled, because dim_date does not carry
    -- them. The effect is one-sided and small: a due date landing on a holiday
    -- is understated by a day, so a handful of filings read as one day late
    -- when they were not.
    select
        periodic_filings.*,
        (periodic_filings.period_end_date
            + periodic_filings.statutory_days)          as statutory_due_date,
        due_calendar.day_of_week                        as due_day_of_week
    from periodic_filings
    left join {{ ref('dim_date') }} as due_calendar
        on due_calendar.date_day
            = periodic_filings.period_end_date + periodic_filings.statutory_days

),

margins as (

    select
        due_dates.*,
        statutory_due_date
            + case due_day_of_week
                when {{ saturday_isodow }} then 2
                when {{ sunday_isodow }}   then 1
                else 0
              end                                       as adjusted_due_date,

        (statutory_due_date
            + case due_day_of_week
                when {{ saturday_isodow }} then 2
                when {{ sunday_isodow }}   then 1
                else 0
              end)
            - filed_date                                as margin_days
    from due_dates

),

classified as (

    -- margin_days is days to spare: positive is early, zero is on the day,
    -- negative is late. A late filing is also a deadline filing, the company
    -- was working to the deadline and missed it, so the flag is an upper
    -- bound on the margin, not a band around zero.
    select
        margins.*,
        (margin_days <= {{ deadline_margin_days }})     as is_deadline_filing,
        (margin_days < 0)                               as is_late_filing,
        row_number() over (
            partition by cik
            order by period_end_date, form_type, filed_date, adsh
        )                                               as filing_seq
    from margins

),

islanded as (

    -- Gap and island over the company's own filing sequence. Subtracting a
    -- dense sequence over the deadline filings from the sequence over all
    -- filings leaves a constant within each unbroken run and a different
    -- constant either side of any filing made early.
    select
        cik,
        filing_seq,
        period_end_date,
        form_type,
        margin_days,
        filing_seq - row_number() over (
            partition by cik order by filing_seq
        )                                               as island_key
    from classified
    where is_deadline_filing

),

runs as (

    select
        cik,
        island_key,
        count(*)                                        as run_length,
        min(period_end_date)                            as run_start_period,
        max(period_end_date)                            as run_end_period,
        min(margin_days)                                as run_min_margin_days
    from islanded
    group by cik, island_key

),

run_summary as (

    select
        cik,
        count(*)                                        as n_deadline_runs,
        max(run_length)                                 as longest_run_filings,
        (array_agg(run_start_period order by run_length desc, run_start_period))[1]
                                                        as longest_run_start_period,
        (array_agg(run_end_period   order by run_length desc, run_start_period))[1]
                                                        as longest_run_end_period
    from runs
    group by cik

),

company_margins as (

    select
        cik,
        count(*)                                        as n_filings,
        count(*) filter (where form_type = '10-K')      as n_annual_filings,
        count(*) filter (where is_deadline_filing)      as n_deadline_filings,
        count(*) filter (where is_late_filing)          as n_late_filings,
        min(period_end_date)                            as first_period,
        max(period_end_date)                            as last_period,
        percentile_cont(0.5) within group (order by margin_days)
                                                        as median_margin_days,
        min(margin_days)                                as min_margin_days,
        max(margin_days)                                as max_margin_days,

        -- The status the company filed under most often. Carried because the
        -- margin is only interpretable against the deadline it was measured on,
        -- and a company can change status mid-range.
        mode() within group (order by filer_status)     as predominant_filer_status
    from classified
    group by cik

),

company_labels as (

    select
        cik,
        company_name,
        sic_code
    from {{ ref('dim_company') }}
    where is_current

),

assembled as (

    select
        margins.cik,
        labels.company_name,
        labels.sic_code,
        margins.predominant_filer_status,
        margins.n_filings,
        margins.n_annual_filings,
        margins.n_deadline_filings,
        margins.n_late_filings,
        margins.first_period,
        margins.last_period,
        margins.median_margin_days,
        margins.min_margin_days,
        margins.max_margin_days,
        coalesce(runs_agg.n_deadline_runs, 0)           as n_deadline_runs,
        coalesce(runs_agg.longest_run_filings, 0)       as longest_run_filings,
        runs_agg.longest_run_start_period,
        runs_agg.longest_run_end_period,
        margins.n_deadline_filings::numeric
            / nullif(margins.n_filings, 0)              as deadline_filing_rate
    from company_margins as margins
    left join run_summary   as runs_agg on runs_agg.cik = margins.cik
    left join company_labels as labels  on labels.cik   = margins.cik

),

rankable as (

    -- The decile population is filtered before the window, not after it. A
    -- company with one filing that happened to land on its due date otherwise
    -- consumes a slot in the tightest decile and pushes a habitual deadline
    -- filer out of it. The four-filing floor is a judgement call: one year of
    -- periodic reporting.
    select
        cik,
        ntile({{ ntile_buckets }}) over (
            order by median_margin_days, deadline_filing_rate desc
        )                                               as margin_decile
    from assembled
    where n_filings >= {{ min_filings_for_ranking }}

),

ranked as (

    select
        assembled.*,
        rankable.margin_decile
    from assembled
    left join rankable
        on rankable.cik = assembled.cik

)

select
    cik,
    company_name,
    sic_code,
    predominant_filer_status,

    n_filings,
    n_annual_filings,
    first_period,
    last_period,

    median_margin_days,
    min_margin_days,
    max_margin_days,

    n_deadline_filings,
    n_late_filings,
    round(100.0 * deadline_filing_rate, 2)              as pct_filings_at_deadline,
    round(100.0 * n_late_filings / nullif(n_filings, 0), 2)
                                                        as pct_filings_late,

    n_deadline_runs,
    longest_run_filings,
    longest_run_start_period,
    longest_run_end_period,

    -- Decile 1 is the tightest margin. Null below the four-filing floor.
    margin_decile,
    (n_filings >= {{ min_filings_for_ranking }})        as is_rankable,

    -- The distinction the model exists to draw. Habitual means the deadline
    -- filings ran back to back for at least three periods; episodic means the
    -- same behaviour arrived in separate bursts with early filings between.
    case
        when n_deadline_filings = 0 then 'never_at_deadline'
        when n_deadline_filings = 1 then 'isolated'
        when longest_run_filings >= {{ consecutive_run_min_length }}
            then 'habitual'
        when n_deadline_runs >= 3 then 'episodic'
        else 'intermittent'
    end                                                 as deadline_pattern

from ranked
order by median_margin_days, deadline_filing_rate desc
