{{ config(materialized='table') }}

/*
  Custom tag share by filer status.

  A company using many company-specific XBRL extensions is harder to compare
  against peers -- its numbers do not line up with anyone else's. This is a real
  comparability problem in fundamental analysis and it varies systematically by
  company size, which makes it a genuine finding rather than a summary statistic.
*/
select
    s.filer_status,
    count(distinct s.cik)                                       as companies,
    count(*)                                                    as total_facts,
    count(*) filter (where n.is_custom_tag)                     as custom_facts,
    round(100.0 * count(*) filter (where n.is_custom_tag)
          / nullif(count(*), 0), 2)                             as pct_custom
from {{ ref('stg_numeric') }} n
join {{ ref('stg_submissions') }} s on s.adsh = n.adsh
where s.filer_status is not null
group by 1
order by pct_custom desc
