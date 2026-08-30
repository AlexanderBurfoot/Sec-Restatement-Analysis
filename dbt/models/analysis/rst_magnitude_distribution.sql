{{ config(materialized='table') }}

/*
  How large are revisions, and do they run in a systematic direction?

  Two histograms of the same rows. The linear one is 5-point buckets of the
  revision as a share of the original; the log one is decades, because the
  observed spread runs from a tenth of a percent to thirteen orders of
  magnitude above it and a linear axis alone puts three quarters of the mass in
  the first few buckets. Direction is a dimension, not a filter, so a downward
  bias shows as a shape difference rather than needing a separate model.
*/

{% set linear_bucket_count = 20 %}
{% set log_min_exponent = -3 %}
{% set log_max_exponent = 3 %}

with revisions as (

    select
        revision_direction,
        pct_revision,
        abs(pct_revision)                                       as abs_pct_revision
    from {{ ref('int_restatements') }}

),

bucketed_linear as (

    -- 0 to 100% in 5-point steps. width_bucket returns count+1 for anything at
    -- or above the upper bound, which is exactly the overflow bucket wanted:
    -- revisions above 100% are real and must not be clamped into the top bin
    -- as though they were 95-100% moves.
    select
        revision_direction,
        'linear_5pt'                                            as bucket_scale,
        width_bucket(
            abs_pct_revision, 0, 1, {{ linear_bucket_count }}
        )                                                       as bucket_index
    from revisions
    where pct_revision is not null

),

bucketed_log as (

    -- One bucket per decade of the revision share. abs_pct_revision is at least
    -- the rounding threshold of 0.001 for every non-null row, by construction
    -- in int_restatements, so the logarithm is always defined and the underflow
    -- bucket is unreachable.
    select
        revision_direction,
        'log10_decade'                                          as bucket_scale,
        width_bucket(
            log(10, abs_pct_revision),
            {{ log_min_exponent }},
            {{ log_max_exponent }},
            {{ log_max_exponent - log_min_exponent }}
        )                                                       as bucket_index
    from revisions
    where pct_revision is not null

),

bucketed_no_denominator as (

    -- Revisions off an originally reported zero. There is no scale to express
    -- them as a share of, so they cannot enter either histogram, but they are
    -- restatements and dropping them silently would make the buckets fail to
    -- reconcile against the source table.
    select
        revision_direction,
        'no_denominator'                                        as bucket_scale,
        1                                                       as bucket_index
    from revisions
    where pct_revision is null

),

all_bucketed as (

    select * from bucketed_linear
    union all select * from bucketed_log
    union all select * from bucketed_no_denominator

),

bucket_counts as (

    -- Direction is rolled up as well as split, so each bucket carries its own
    -- count and the both-directions count for comparison.
    select
        bucket_scale,
        coalesce(revision_direction, 'all')                     as revision_direction,
        bucket_index,
        count(*)                                                as restatements
    from all_bucketed
    group by grouping sets (
        (bucket_scale, revision_direction, bucket_index),
        (bucket_scale, bucket_index)
    )

),

direction_totals as (

    select
        bucket_scale,
        revision_direction,
        sum(restatements)                                       as restatements_in_direction
    from bucket_counts
    group by bucket_scale, revision_direction

),

direction_percentiles as (

    -- Constant within a direction and repeated onto every bucket row, so the
    -- spread and the shape can be read off a single result without a second
    -- query. Percentiles are of the unsigned share; the signed median is
    -- carried alongside because it, not the spread, is what shows a bias.
    select
        coalesce(revision_direction, 'all')                     as revision_direction,
        percentile_cont(0.50) within group (order by abs_pct_revision) as p50_abs_pct_revision,
        percentile_cont(0.75) within group (order by abs_pct_revision) as p75_abs_pct_revision,
        percentile_cont(0.90) within group (order by abs_pct_revision) as p90_abs_pct_revision,
        percentile_cont(0.99) within group (order by abs_pct_revision) as p99_abs_pct_revision,
        percentile_cont(0.50) within group (order by pct_revision)     as median_signed_pct_revision
    from revisions
    where pct_revision is not null
    group by grouping sets ((revision_direction), ())

)

select
    counts.bucket_scale,
    counts.revision_direction,
    counts.bucket_index,

    case
        when counts.bucket_scale = 'no_denominator'
            then 'first reported value was zero'
        when counts.bucket_scale = 'linear_5pt'
            then case
                when counts.bucket_index > {{ linear_bucket_count }} then '>100%'
                else ((counts.bucket_index - 1) * 5)::text
                     || '-' || (counts.bucket_index * 5)::text || '%'
            end
        else case
            when counts.bucket_index > {{ log_max_exponent - log_min_exponent }}
                then '>=100,000%'
            else '10^' || ({{ log_min_exponent }} + counts.bucket_index - 1)::text
                 || ' to 10^' || ({{ log_min_exponent }} + counts.bucket_index)::text
        end
    end                                                         as bucket_label,

    counts.restatements,
    totals.restatements_in_direction,
    round(100.0 * counts.restatements
          / nullif(totals.restatements_in_direction, 0), 3)     as pct_of_direction,

    round(percentiles.p50_abs_pct_revision::numeric, 4)         as p50_abs_pct_revision,
    round(percentiles.p75_abs_pct_revision::numeric, 4)         as p75_abs_pct_revision,
    round(percentiles.p90_abs_pct_revision::numeric, 4)         as p90_abs_pct_revision,
    round(percentiles.p99_abs_pct_revision::numeric, 4)         as p99_abs_pct_revision,
    round(percentiles.median_signed_pct_revision::numeric, 4)   as median_signed_pct_revision

from bucket_counts as counts
join direction_totals as totals
    on  totals.bucket_scale = counts.bucket_scale
    and totals.revision_direction = counts.revision_direction
left join direction_percentiles as percentiles
    on percentiles.revision_direction = counts.revision_direction
order by
    counts.bucket_scale,
    counts.revision_direction,
    counts.bucket_index
