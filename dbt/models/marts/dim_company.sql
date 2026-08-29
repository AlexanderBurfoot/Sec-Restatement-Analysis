{{ config(materialized='table') }}

{% set open_end_date = "date '9999-12-31'" %}

/*
  Company attributes as they stood on each filing date, versioned Type 2.

  A fact is joined to this dimension on the date it was filed, not the period it
  describes, so a 2023 figure carries the name and SIC the company had in 2023
  even if it has since renamed or reclassified. Without that, restatement
  comparisons would attribute every historical fact to a company's present-day
  identity.
*/

with ranked_filings as (

    select
        cik,
        filed_date,
        company_name,
        sic_code,
        fiscal_year_end_mmdd,
        business_state,

        -- Several filings can share a filing date; taking all of them would
        -- produce zero-length validity intervals. One row per (cik, filed_date)
        -- is chosen by: the most recent period reported, then the most complete
        -- attribute set, then adsh for determinism. Completeness matters because
        -- registration statements (POS AM, F-1, 424B3) filed alongside a 10-K or
        -- 20-F carry a blank fye that would otherwise read as a real change.
        row_number() over (
            partition by cik, filed_date
            order by
                period_end_date desc nulls last,
                (case when sic_code is null then 0 else 1 end
                 + case when fiscal_year_end_mmdd is null then 0 else 1 end
                 + case when business_state is null then 0 else 1 end) desc,
                adsh
        ) as filing_rank

    from {{ ref('stg_submissions') }}
    where cik is not null
      and filed_date is not null

),

daily_attributes as (

    select
        cik,
        filed_date,
        company_name,
        sic_code,
        fiscal_year_end_mmdd,
        business_state
    from ranked_filings
    where filing_rank = 1

),

change_flagged as (

    select
        cik,
        filed_date,
        company_name,
        sic_code,
        fiscal_year_end_mmdd,
        business_state,

        -- `is distinct from`, not `<>`: every versioned attribute except the
        -- name is nullable, and null-to-value is a change worth versioning.
        (
            lag(filed_date) over attribute_history is null
            or company_name
                is distinct from lag(company_name) over attribute_history
            or sic_code
                is distinct from lag(sic_code) over attribute_history
            or fiscal_year_end_mmdd
                is distinct from lag(fiscal_year_end_mmdd) over attribute_history
            or business_state
                is distinct from lag(business_state) over attribute_history
        ) as starts_new_version

    from daily_attributes
    window attribute_history as (partition by cik order by filed_date)

),

version_starts as (

    select
        cik,
        filed_date as valid_from,
        company_name,
        sic_code,
        fiscal_year_end_mmdd,
        business_state
    from change_flagged
    where starts_new_version

),

effective_dated as (

    select
        cik,
        valid_from,
        company_name,
        sic_code,
        fiscal_year_end_mmdd,
        business_state,

        -- Inclusive upper bound, so downstream range joins read
        -- `filed_date between valid_from and valid_to`.
        coalesce(
            lead(valid_from) over version_sequence - 1,
            {{ open_end_date }}
        ) as valid_to,

        row_number() over version_sequence as version_number

    from version_starts
    window version_sequence as (partition by cik order by valid_from)

)

select
    {{ dbt_utils.generate_surrogate_key(['cik', 'valid_from']) }} as company_sk,
    cik,
    company_name,
    sic_code,
    fiscal_year_end_mmdd,
    business_state,
    valid_from,
    valid_to,
    version_number,
    (valid_to = {{ open_end_date }}) as is_current
from effective_dated
