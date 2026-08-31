-- The comparison in scripts/train_compare.py is only meaningful if the two
-- feature tables differ in nothing but the visibility rule. A filing present in
-- one and not the other, or labelled differently between them, would make the
-- two models answer different questions and turn the AUC gap into an artefact of
-- the population rather than a measure of the leak.
--
-- Returns one row per disagreement, so a failure names the filing.

select
    coalesce(pit.adsh, naive.adsh)  as adsh,
    pit.adsh is null                as missing_from_pit,
    naive.adsh is null              as missing_from_naive,
    pit.was_restated                as pit_label,
    naive.was_restated              as naive_label
from {{ ref('feat_filing_pit') }} as pit
full outer join {{ ref('feat_filing_naive') }} as naive
    on naive.adsh = pit.adsh
where pit.adsh is null
   or naive.adsh is null
   or pit.was_restated is distinct from naive.was_restated
