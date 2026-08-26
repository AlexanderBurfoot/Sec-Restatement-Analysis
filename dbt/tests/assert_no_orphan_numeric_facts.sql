select n.adsh, count(*) as orphan_facts
from {{ ref('stg_numeric') }} n
left join {{ ref('stg_submissions') }} s on s.adsh = n.adsh
where s.adsh is null
group by 1
