-- Type 2 versions of one cik must partition the timeline, not overlap it.
-- Two filings on the same date are the usual cause: if they survive into
-- version_starts, lead(valid_from) - 1 lands on or before valid_from and the
-- interval collides with its neighbour.
select
    earlier.cik,
    earlier.company_sk       as earlier_sk,
    earlier.valid_from       as earlier_valid_from,
    earlier.valid_to         as earlier_valid_to,
    later.company_sk         as later_sk,
    later.valid_from         as later_valid_from,
    later.valid_to           as later_valid_to
from {{ ref('dim_company') }} earlier
join {{ ref('dim_company') }} later
  on later.cik = earlier.cik
 and later.company_sk <> earlier.company_sk
where earlier.valid_from <= later.valid_to
  and later.valid_from <= earlier.valid_to
