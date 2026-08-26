{{ config(materialized='table') }}

-- Companies using company-specific XBRL extensions are harder to compare
-- against peers: their numbers do not line up with anyone else's. The custom
-- flag lives in the tag dictionary, not on the fact.
select
    s.filer_status,
    count(distinct s.cik)                                   as companies,
    count(*)                                                as total_facts,
    count(*) filter (where t.is_custom)                     as custom_facts,
    round(100.0 * count(*) filter (where t.is_custom)
          / nullif(count(*), 0), 2)                         as pct_custom
from {{ ref('stg_numeric') }} n
join {{ ref('stg_submissions') }} s on s.adsh = n.adsh
left join {{ ref('stg_tags') }} t
       on t.tag = n.tag
      and t.taxonomy_version = n.taxonomy_version
where s.filer_status is not null
group by 1
order by pct_custom desc
