-- The grain check that makes the range join honest.
--
-- fct_financial_fact inner joins every fact to exactly one dim_company version
-- on filed_date. If the Type 2 validity intervals leave a gap the join drops
-- facts; if they overlap it duplicates them. Either way this count diverges,
-- and the divergence is the diagnosis. Do not replace the inner join with a
-- left join to make it pass.
with fact_rows as (

    select count(*) as n_rows
    from {{ ref('fct_financial_fact') }}

),

staging_rows as (

    select count(*) as n_rows
    from {{ ref('stg_numeric') }}

)

select
    fact_rows.n_rows                        as fact_row_count,
    staging_rows.n_rows                     as staging_row_count,
    fact_rows.n_rows - staging_rows.n_rows  as difference
from fact_rows
cross join staging_rows
where fact_rows.n_rows <> staging_rows.n_rows
