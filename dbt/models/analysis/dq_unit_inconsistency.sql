{{ config(materialized='table') }}

-- The same tag reported in more than one unit of measure. Usually legitimate
-- (a share count vs a dollar amount), sometimes a genuine tagging error. The
-- point is to quantify it, not to fix it.
select
    tag,
    count(distinct unit_of_measure)                     as distinct_units,
    string_agg(distinct unit_of_measure, ', ' order by unit_of_measure) as units_used,
    count(*)                                            as total_facts
from {{ ref('stg_numeric') }}
where value is not null
group by tag
having count(distinct unit_of_measure) > 1
order by distinct_units desc, total_facts desc
