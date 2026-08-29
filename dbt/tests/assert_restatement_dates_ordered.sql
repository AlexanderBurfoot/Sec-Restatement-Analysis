-- A restatement requires that time passed between two publications.
--
-- If this returns rows the partition has collapsed something it should have
-- kept apart: two facts published on the same day are a same-day conflict or a
-- duplicate composite key, not a revision of one by the other. int_restatements
-- excludes single-date groups in its having clause, so any row here means that
-- exclusion stopped working.
select
    restatement_sk,
    cik,
    tag,
    period_end_date,
    first_filed_date,
    latest_filed_date,
    first_adsh,
    latest_adsh
from {{ ref('int_restatements') }}
where first_filed_date >= latest_filed_date
