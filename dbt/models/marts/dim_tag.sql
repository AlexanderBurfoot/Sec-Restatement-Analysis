{{ config(materialized='table') }}

/*
  The XBRL tag dictionary, one row per (tag, taxonomy_version).

  Type 1, overwritten on every run, because tag.txt is a full dictionary
  snapshot in every quarterly ZIP rather than a change feed: the SEC corrects a
  label or datatype in place under the same taxonomy version, so a revised
  definition should read as though it had always been correct. Genuine change is
  expressed by publishing a new taxonomy_version, which is already part of the
  grain. The history this project cares about lives in the facts, not here.
*/

with placement_counts as (

    -- A tag's statement placement is a property of each filing that uses it,
    -- not of the dictionary, so the same tag can be presented on more than one
    -- statement. Count how often each placement was seen.
    select
        tag,
        taxonomy_version,
        statement_code,
        statement_name,
        count(*) as n_presentations
    from {{ ref('stg_presentation') }}
    where statement_code is not null
    group by tag, taxonomy_version, statement_code, statement_name

),

ranked_placements as (

    select
        tag,
        taxonomy_version,
        statement_code,
        statement_name,
        row_number() over (
            partition by tag, taxonomy_version
            order by n_presentations desc, statement_code
        ) as placement_rank,

        -- Carried alongside the modal placement so that collapsing to one
        -- statement stays visible downstream instead of being silently lost.
        count(*) over (partition by tag, taxonomy_version)
            as n_statement_placements
    from placement_counts

),

modal_placement as (

    select
        tag,
        taxonomy_version,
        statement_code,
        statement_name,
        n_statement_placements
    from ranked_placements
    where placement_rank = 1

)

select
    {{ dbt_utils.generate_surrogate_key(['tags.tag', 'tags.taxonomy_version']) }}
                                            as tag_sk,
    tags.tag,
    tags.taxonomy_version,
    tags.tag_label,
    tags.is_custom,
    tags.natural_balance,
    tags.instant_or_duration,
    placement.statement_code,
    placement.statement_name,

    -- Zero where the tag is defined in the dictionary but never presented on a
    -- statement in the loaded range.
    coalesce(placement.n_statement_placements, 0) as n_statement_placements
from {{ ref('stg_tags') }} as tags
left join modal_placement as placement
    on  tags.tag = placement.tag
    and tags.taxonomy_version = placement.taxonomy_version
