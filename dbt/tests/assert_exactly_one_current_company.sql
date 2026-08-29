-- Every cik has exactly one open-ended version: the attributes as of its most
-- recent filing.
select
    cik,
    count(*)                                    as versions,
    count(*) filter (where is_current)          as current_versions
from {{ ref('dim_company') }}
group by cik
having count(*) filter (where is_current) <> 1
