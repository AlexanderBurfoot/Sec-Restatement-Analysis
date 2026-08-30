{{
    config(
        materialized='table',
        pre_hook="set work_mem = '512MB'"
    )
}}

/*
  Which line items get revised, and on which financial statement do they sit?

  int_restatements is keyed on tag without taxonomy_version — deliberately, so
  the same concept under us-gaap/2023 and us-gaap/2024 stays one fact — while
  dim_tag is keyed on both. The dictionary is therefore collapsed to tag grain
  here, and a tag presented on more than one statement is flagged rather than
  quietly assigned to one.
*/

{% set top_tags_per_statement = 15 %}

with tag_statement as (

    -- Modal statement across the taxonomy versions that define the tag, ranked
    -- by how many versions agree. n_placements_across_versions above 1 marks a
    -- tag whose statement is a majority choice, not a fact about it.
    select distinct on (tag)
        tag,
        statement_code,
        statement_name,
        is_custom,
        count(*) over (partition by tag)                        as n_placements_across_versions
    from (
        select
            tag,
            statement_code,
            statement_name,
            bool_or(is_custom)                                  as is_custom,
            count(*)                                            as n_taxonomy_versions
        from {{ ref('dim_tag') }}
        where statement_code is not null
        group by tag, statement_code, statement_name
    ) as placements
    order by tag, n_taxonomy_versions desc, statement_code

),

revisable_groups as (

    -- Same denominator as rst_by_sector: described facts reported on more than
    -- one date, and so capable of being revised. A tag reported on every filing
    -- accumulates revisions by exposure alone, which is what this divides out.
    select
        tag
    from {{ ref('fct_financial_fact') }}
    where value is not null
    group by cik, coregistrant, segments, tag, period_end_date, qtrs, unit_of_measure
    having count(distinct filed_date) > 1

),

revisable_by_tag as (

    -- Collapsed to tag grain before the rollup. Every revisable group belongs
    -- to exactly one tag, so summing these counts up to a statement is exact.
    select
        tag,
        count(*)                                                as revisable_groups
    from revisable_groups
    group by tag

),

revisable_placed as (

    select
        coalesce(placement.statement_code, 'NP')                as statement_code,
        coalesce(placement.statement_name, 'Not presented')     as statement_name,
        revisable.tag,
        coalesce(placement.is_custom, false)                    as is_custom,
        coalesce(placement.n_placements_across_versions, 0)     as n_placements_across_versions,
        revisable.revisable_groups
    from revisable_by_tag as revisable
    left join tag_statement as placement
        on placement.tag = revisable.tag

),

revisable_agg as (

    select
        statement_code,
        statement_name,
        tag,
        grouping(statement_code, tag)                           as grouping_level,
        sum(revisable_groups)                                   as revisable_groups,
        count(*)                                                as distinct_tags,
        bool_or(is_custom)                                      as includes_custom_tag,
        bool_or(n_placements_across_versions > 1)               as placement_is_ambiguous
    from revisable_placed
    group by grouping sets (
        (statement_code, statement_name, tag),
        (statement_code, statement_name),
        ()
    )

),

restated_placed as (

    -- Driven off the restatement rows themselves rather than off a per-tag
    -- pre-aggregate, because distinct companies do not sum across tags: one
    -- filer revising ten line items is one company, not ten.
    select
        coalesce(placement.statement_code, 'NP')                as statement_code,
        coalesce(placement.statement_name, 'Not presented')     as statement_name,
        restatements_model.tag,
        restatements_model.cik,
        restatements_model.revision_direction,
        abs(restatements_model.pct_revision)                    as abs_pct_revision
    from {{ ref('int_restatements') }} as restatements_model
    left join tag_statement as placement
        on placement.tag = restatements_model.tag

),

restated_agg as (

    select
        statement_code,
        tag,
        grouping(statement_code, tag)                           as grouping_level,
        count(*)                                                as restatements,
        count(distinct cik)                                     as restating_companies,
        count(*) filter (where revision_direction = 'decrease')  as downward_restatements,
        percentile_cont(0.5) within group (order by abs_pct_revision)
                                                                as median_abs_pct_revision
    from restated_placed
    group by grouping sets (
        (statement_code, tag),
        (statement_code),
        ()
    )

),

combined as (

    -- Driven from the revisable side, which is the complete tag universe: a tag
    -- reported repeatedly and never revised is a real zero and belongs in the
    -- statement's denominator.
    select
        revisable.statement_code,
        revisable.statement_name,
        revisable.tag,
        revisable.grouping_level,
        revisable.revisable_groups,
        revisable.distinct_tags,
        revisable.includes_custom_tag,
        revisable.placement_is_ambiguous,
        coalesce(restated.restatements, 0)                      as restatements,
        coalesce(restated.restating_companies, 0)               as restating_companies,
        coalesce(restated.downward_restatements, 0)             as downward_restatements,
        restated.median_abs_pct_revision
    from revisable_agg as revisable
    left join restated_agg as restated
        on  restated.grouping_level  = revisable.grouping_level
        and restated.statement_code is not distinct from revisable.statement_code
        and restated.tag            is not distinct from revisable.tag

),

ranked as (

    select
        combined.*,
        row_number() over (
            partition by statement_code
            order by restatements desc, tag
        )                                                       as rank_within_statement
    from combined
    where grouping_level = 0

),

trimmed as (

    -- Statement and grand totals are computed over every tag; only the
    -- tag-level detail is trimmed, so a total is never the sum of the rows
    -- displayed beneath it.
    select *, null::bigint as rank_within_statement
    from combined
    where grouping_level > 0

    union all

    select * from ranked
    where rank_within_statement <= {{ top_tags_per_statement }}

)

select
    coalesce(statement_code, 'ALL')                             as statement_code,
    coalesce(statement_name, 'All statements')                  as statement_name,
    tag,
    case grouping_level
        when 0 then 'tag'
        when 1 then 'statement'
        else 'grand_total'
    end                                                         as aggregation_level,
    rank_within_statement,
    restatements,
    revisable_groups,
    restating_companies,
    distinct_tags,
    round(100.0 * restatements / nullif(revisable_groups, 0), 3)
                                                                as pct_of_revisable_restated,
    round(100.0 * downward_restatements / nullif(restatements, 0), 2)
                                                                as pct_restatements_downward,
    round(median_abs_pct_revision::numeric, 4)                  as median_abs_pct_revision,
    includes_custom_tag,
    placement_is_ambiguous
from trimmed
order by
    grouping_level desc,
    restatements desc,
    rank_within_statement
