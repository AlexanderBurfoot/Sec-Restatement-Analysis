{{
    config(
        materialized='table',
        pre_hook="set work_mem = '512MB'"
    )
}}

/*
  What it costs to ignore the two dates.

  Two peer comparisons over the identical companies and the identical fiscal
  year. The first uses only what was knowable on the cutoff date: facts filed
  strictly before it, and each company's SIC as recorded on the dim_company
  version current then. The second uses every filing in the loaded range and
  each company's present-day SIC. Same metric, same peer universe, same period.
  Everything that differs between them is a revision arriving after the cutoff,
  a reclassification, or a peer's revision moving the distribution.

  This is what the warehouse is for. A model trained, a screen run or a
  benchmark published against the second view and back-tested as though it were
  the first is reading numbers that did not exist on the date it claims to
  stand on. The count of companies that land in a different quartile is the
  size of that error.

  The fiscal period is fixed to whatever the company reported at the cutoff and
  is not re-selected for the second view. Letting it move would compare a
  restatement against a newer annual period and measure the wrong thing.
*/

{% set point_in_time_cutoff = "date '2024-06-30'" %}
{% set open_end_date        = "date '9999-12-31'" %}

-- The target fiscal year: annual periods ending in the second half of 2023.
-- Chosen so that every company in the population had filed by the cutoff and
-- had eighteen months of the loaded range afterwards in which to revise.
{% set target_period_start = "date '2023-06-30'" %}
{% set target_period_end   = "date '2023-12-31'" %}

-- A prior-year comparative is any annual period ending between these many days
-- before the target period end. The band absorbs 52/53-week fiscal calendars,
-- which do not land on the same date each year.
{% set prior_year_min_days = 350 %}
{% set prior_year_max_days = 380 %}

-- Quartiles over fewer peers than this are noise, so the SIC major group is
-- dropped from both views rather than ranked. A judgement call.
{% set min_peers_for_percentile = 20 %}
{% set percentile_buckets = 4 %}

-- A quartile change is called material only if the company's rank within its
-- peer group also moved by at least this much. Derived from the observed
-- separation between the two mechanisms that move a bucket: where the company's
-- own inputs were restated the median rank shift is 0.044 for margin and 0.235
-- for growth, while where only the peer distribution moved the median is 0.010
-- and the largest shift in the entire model is 0.056. Companies sitting within
-- a hundredth of a quartile cut change bucket when four peers join their SIC
-- group without anything about them changing, and counting those alongside a
-- genuine reordering would overstate the headline by roughly half.
{% set material_percentile_shift = 0.05 %}

with as_of_dates as (

    -- The two views differ only in this date. Everything downstream is written
    -- once and evaluated twice, so the point-in-time view cannot drift from the
    -- latest view on anything except the visibility rule itself.
    select 'point_in_time' as as_of_label, {{ point_in_time_cutoff }} as as_of_date
    union all
    select 'latest'        as as_of_label, {{ open_end_date }}        as as_of_date

),

annual_facts as (

    -- Consolidated annual figures only. A segment-level or subsidiary row is a
    -- different described fact, and a non-USD row is not comparable to a USD
    -- peer without an FX rate this project does not carry.
    select
        cik,
        tag,
        period_end_date,
        filed_date,
        value
    from {{ ref('fct_financial_fact') }}
    where qtrs = 4
      and segments = ''
      and coregistrant = ''
      and unit_of_measure = 'USD'
      and value is not null
      and tag in (
            'RevenueFromContractWithCustomerExcludingAssessedTax',
            'Revenues',
            'RevenueFromContractWithCustomerIncludingAssessedTax',
            'NetIncomeLoss'
          )
      and period_end_date
            between {{ target_period_start }} - interval '{{ prior_year_max_days }} days'
                and {{ target_period_end }}

),

best_known_value as (

    -- The value a reader would have had on the as-of date: the one from the
    -- latest filing visible then. value is the second tiebreaker for the same
    -- reason int_restatements needs it — the duplicate-composite-key defect
    -- puts two values on one accession, and without it the pick is whatever
    -- order the scan returned and the model is not idempotent.
    select distinct on (as_of_dates.as_of_label, annual_facts.cik, annual_facts.tag, annual_facts.period_end_date)
        as_of_dates.as_of_label,
        annual_facts.cik,
        annual_facts.tag,
        annual_facts.period_end_date,
        annual_facts.value,
        annual_facts.filed_date
    from annual_facts
    cross join as_of_dates
    where annual_facts.filed_date < as_of_dates.as_of_date
    order by
        as_of_dates.as_of_label,
        annual_facts.cik,
        annual_facts.tag,
        annual_facts.period_end_date,
        annual_facts.filed_date desc,
        annual_facts.value desc

),

revenue as (

    -- Revenue is reported under three tags that mean the same line. The
    -- priority is applied per view rather than fixed across both, because a
    -- company that switched tags in a later filing genuinely has a different
    -- best-known revenue afterwards; forcing the earlier tag would hide a real
    -- change behind a modelling choice.
    select distinct on (as_of_label, cik, period_end_date)
        as_of_label,
        cik,
        period_end_date,
        tag                                             as revenue_tag,
        value                                           as revenue
    from best_known_value
    where tag <> 'NetIncomeLoss'
    order by
        as_of_label,
        cik,
        period_end_date,
        case tag
            when 'RevenueFromContractWithCustomerExcludingAssessedTax' then 1
            when 'Revenues'                                            then 2
            else 3
        end,
        filed_date desc

),

net_income as (

    select
        as_of_label,
        cik,
        period_end_date,
        value                                           as net_income
    from best_known_value
    where tag = 'NetIncomeLoss'

),

with_prior_year as (

    -- The prior-year comparative is read from the same view, so growth measured
    -- at the cutoff uses the prior year as it stood at the cutoff too. Taking
    -- the closest match to exactly one year keeps a company with two period
    -- ends inside the band from multiplying the row.
    select
        revenue.as_of_label,
        revenue.cik,
        revenue.period_end_date,
        revenue.revenue_tag,
        revenue.revenue,
        net_income.net_income,
        prior.revenue                                   as prior_year_revenue,
        prior.period_end_date                           as prior_year_period_end_date
    from revenue
    join net_income
        on  net_income.as_of_label = revenue.as_of_label
        and net_income.cik = revenue.cik
        and net_income.period_end_date = revenue.period_end_date
    join lateral (
        select
            candidate.revenue,
            candidate.period_end_date
        from revenue as candidate
        where candidate.as_of_label = revenue.as_of_label
          and candidate.cik = revenue.cik
          and candidate.period_end_date
                between revenue.period_end_date - interval '{{ prior_year_max_days }} days'
                    and revenue.period_end_date - interval '{{ prior_year_min_days }} days'
        order by abs(revenue.period_end_date - candidate.period_end_date)
        limit 1
    ) as prior on true
    where revenue.period_end_date between {{ target_period_start }} and {{ target_period_end }}
      and revenue.revenue > 0
      and prior.revenue > 0

),

target_period as (

    -- The period is chosen once, from the point-in-time view, and both views
    -- are then pinned to it. A company reporting two annual periods inside the
    -- window takes the later one.
    select
        cik,
        max(period_end_date)                            as period_end_date
    from with_prior_year
    where as_of_label = 'point_in_time'
    group by cik

),

company_sic as (

    -- The SIC as of each view's own date. The range join is what makes the
    -- Type 2 dimension do work here: the latest view resolves to the current
    -- version because its as-of date is the open end date.
    select
        as_of_dates.as_of_label,
        dim_company.cik,
        dim_company.sic_code,
        case
            when dim_company.sic_code ~ '^[0-9]{4}$' then left(dim_company.sic_code, 2)
        end                                             as sic_major_group
    from {{ ref('dim_company') }} as dim_company
    cross join as_of_dates
    where as_of_dates.as_of_date between dim_company.valid_from and dim_company.valid_to

),

metrics as (

    select
        with_prior_year.as_of_label,
        with_prior_year.cik,
        with_prior_year.period_end_date,
        company_sic.sic_code,
        company_sic.sic_major_group,
        with_prior_year.revenue_tag,
        with_prior_year.revenue,
        with_prior_year.net_income,
        with_prior_year.prior_year_revenue,
        with_prior_year.net_income / with_prior_year.revenue         as net_margin,
        with_prior_year.revenue / with_prior_year.prior_year_revenue - 1
                                                                     as revenue_growth
    from with_prior_year
    join target_period
        on  target_period.cik = with_prior_year.cik
        and target_period.period_end_date = with_prior_year.period_end_date
    join company_sic
        on  company_sic.as_of_label = with_prior_year.as_of_label
        and company_sic.cik = with_prior_year.cik
    where company_sic.sic_major_group is not null

),

population as (

    -- Both views, or neither. Holding the population fixed is what makes the
    -- comparison about the data rather than about who had filed: a company
    -- absent from one side would otherwise shift every peer's rank on the
    -- other and be counted as a change it did not cause.
    select cik
    from metrics
    group by cik
    having count(distinct as_of_label) = 2

),

peer_group_sizes as (

    select
        metrics.as_of_label,
        metrics.sic_major_group,
        count(*)                                        as n_peers
    from metrics
    join population on population.cik = metrics.cik
    group by 1, 2

),

ranked as (

    select
        metrics.*,
        peer_group_sizes.n_peers,

        percent_rank() over margin_within_peers          as margin_percentile,
        {{ percentile_buckets }} + 1
            - ntile({{ percentile_buckets }}) over margin_within_peers
                                                        as margin_quartile,

        percent_rank() over growth_within_peers          as growth_percentile,
        {{ percentile_buckets }} + 1
            - ntile({{ percentile_buckets }}) over growth_within_peers
                                                        as growth_quartile

    from metrics
    join population on population.cik = metrics.cik
    join peer_group_sizes
        on  peer_group_sizes.as_of_label = metrics.as_of_label
        and peer_group_sizes.sic_major_group = metrics.sic_major_group
    where peer_group_sizes.n_peers >= {{ min_peers_for_percentile }}
    window
        -- Quartile 1 is the best performer, so ntile over an ascending order is
        -- reversed rather than the order flipped: descending would put nulls
        -- first, and there are none here only because both metrics are
        -- non-null by construction.
        margin_within_peers as (
            partition by metrics.as_of_label, metrics.sic_major_group
            order by metrics.net_margin
        ),
        growth_within_peers as (
            partition by metrics.as_of_label, metrics.sic_major_group
            order by metrics.revenue_growth
        )

),

point_in_time_view as (
    select * from ranked where as_of_label = 'point_in_time'
),

latest_view as (
    select * from ranked where as_of_label = 'latest'
),

compared as (

    select
        point_in_time.cik,
        point_in_time.period_end_date,

        point_in_time.sic_code                          as pit_sic_code,
        latest.sic_code                                 as latest_sic_code,
        point_in_time.sic_major_group                   as pit_sic_major_group,
        latest.sic_major_group                          as latest_sic_major_group,
        point_in_time.n_peers                           as pit_n_peers,
        latest.n_peers                                  as latest_n_peers,

        point_in_time.revenue                           as pit_revenue,
        latest.revenue                                  as latest_revenue,
        point_in_time.net_income                        as pit_net_income,
        latest.net_income                               as latest_net_income,
        point_in_time.prior_year_revenue                as pit_prior_year_revenue,
        latest.prior_year_revenue                       as latest_prior_year_revenue,

        point_in_time.net_margin                        as pit_net_margin,
        latest.net_margin                               as latest_net_margin,
        point_in_time.margin_percentile                 as pit_margin_percentile,
        latest.margin_percentile                        as latest_margin_percentile,
        point_in_time.margin_quartile                   as pit_margin_quartile,
        latest.margin_quartile                          as latest_margin_quartile,

        point_in_time.revenue_growth                    as pit_revenue_growth,
        latest.revenue_growth                           as latest_revenue_growth,
        point_in_time.growth_percentile                 as pit_growth_percentile,
        latest.growth_percentile                        as latest_growth_percentile,
        point_in_time.growth_quartile                   as pit_growth_quartile,
        latest.growth_quartile                          as latest_growth_quartile,

        (point_in_time.sic_major_group
            is distinct from latest.sic_major_group)    as sic_group_changed,

        (   point_in_time.revenue           is distinct from latest.revenue
         or point_in_time.net_income        is distinct from latest.net_income
         or point_in_time.prior_year_revenue is distinct from latest.prior_year_revenue
        )                                               as own_values_changed

    from point_in_time_view as point_in_time
    join latest_view as latest
        on latest.cik = point_in_time.cik

),

labelled as (

    select
        compared.*,
        (pit_margin_quartile is distinct from latest_margin_quartile)
                                                        as margin_quartile_changed,
        (pit_growth_quartile is distinct from latest_growth_quartile)
                                                        as growth_quartile_changed,
        latest_margin_percentile - pit_margin_percentile as margin_percentile_shift,
        latest_growth_percentile - pit_growth_percentile as growth_percentile_shift
    from compared

)

select
    labelled.cik,
    company_labels.company_name,
    labelled.period_end_date,

    labelled.pit_sic_code,
    labelled.latest_sic_code,
    labelled.pit_sic_major_group,
    labelled.latest_sic_major_group,
    labelled.sic_group_changed,
    labelled.pit_n_peers,
    labelled.latest_n_peers,

    labelled.pit_revenue,
    labelled.latest_revenue,
    labelled.pit_net_income,
    labelled.latest_net_income,
    labelled.pit_prior_year_revenue,
    labelled.latest_prior_year_revenue,
    labelled.own_values_changed,

    round(labelled.pit_net_margin::numeric, 6)                   as pit_net_margin,
    round(labelled.latest_net_margin::numeric, 6)                as latest_net_margin,
    round(labelled.pit_margin_percentile::numeric, 4)   as pit_margin_percentile,
    round(labelled.latest_margin_percentile::numeric, 4) as latest_margin_percentile,
    labelled.pit_margin_quartile,
    labelled.latest_margin_quartile,
    labelled.margin_quartile_changed,
    labelled.latest_margin_quartile - labelled.pit_margin_quartile
                                                        as margin_quartile_shift,
    round(labelled.margin_percentile_shift::numeric, 4)  as margin_percentile_shift,
    (labelled.margin_quartile_changed
        and abs(labelled.margin_percentile_shift) >= {{ material_percentile_shift }})
                                                        as margin_change_is_material,

    round(labelled.pit_revenue_growth::numeric, 6)               as pit_revenue_growth,
    round(labelled.latest_revenue_growth::numeric, 6)            as latest_revenue_growth,
    round(labelled.pit_growth_percentile::numeric, 4)   as pit_growth_percentile,
    round(labelled.latest_growth_percentile::numeric, 4) as latest_growth_percentile,
    labelled.pit_growth_quartile,
    labelled.latest_growth_quartile,
    labelled.growth_quartile_changed,
    labelled.latest_growth_quartile - labelled.pit_growth_quartile
                                                        as growth_quartile_shift,
    round(labelled.growth_percentile_shift::numeric, 4)  as growth_percentile_shift,
    (labelled.growth_quartile_changed
        and abs(labelled.growth_percentile_shift) >= {{ material_percentile_shift }})
                                                        as growth_change_is_material,

    (labelled.margin_quartile_changed or labelled.growth_quartile_changed)
                                                        as any_quartile_changed,

    -- The headline the model exists to produce, and the reason it is stated
    -- with the materiality qualifier rather than without it.
    (   (labelled.margin_quartile_changed
            and abs(labelled.margin_percentile_shift) >= {{ material_percentile_shift }})
     or (labelled.growth_quartile_changed
            and abs(labelled.growth_percentile_shift) >= {{ material_percentile_shift }})
    )                                                   as any_material_quartile_change,

    -- Why the bucket moved. A company whose own inputs and SIC both held still
    -- can still change quartile, because its peers' numbers moved underneath
    -- it. That case is the one most easily mistaken for stability.
    case
        when not (labelled.margin_quartile_changed or labelled.growth_quartile_changed)
            then 'unchanged'
        when labelled.own_values_changed and labelled.sic_group_changed
            then 'restated_and_reclassified'
        when labelled.own_values_changed then 'own_values_restated'
        when labelled.sic_group_changed  then 'sic_reclassified'
        else 'peer_distribution_moved'
    end                                                 as change_attribution

from labelled
left join {{ ref('dim_company') }} as company_labels
    on  company_labels.cik = labelled.cik
    and company_labels.is_current
order by labelled.cik
