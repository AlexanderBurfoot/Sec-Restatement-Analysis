{{
    config(
        materialized='incremental',
        unique_key='financial_fact_sk',
        incremental_strategy='delete+insert',
        on_schema_change='append_new_columns',
        indexes=[{'columns': ['financial_fact_sk'], 'type': 'btree'}]
    )
}}

{% set amendment_lookback_days = 30 %}

/*
  One row per reported number per filing, at the full composite key including
  segments. The SEC documents the key without segments; testing on the
  documented key produced 4,635,667 violations against 154 on this one.

  Company attributes are attached by range join on filed_date, not on
  is_current, so a fact carries the identity the filer had when the number was
  published. Joining on the current version would restate every historical fact
  under today's name and SIC and make the Type 2 dimension decorative.

  Incremental because amendments for old periods arrive continuously: the
  lookback rebuilds a trailing window of filing dates rather than assuming the
  newest filed_date is a watermark past which nothing changes.
*/

with submissions as (

    select
        adsh,
        cik,
        filed_date
    from {{ ref('stg_submissions') }}

    {% if is_incremental() %}
    -- Filed date, never period end date: an amendment to a 2023 quarter filed
    -- last week is new work, and a period-based filter would never see it.
    where filed_date >= (
        select max(filed_date) from {{ this }}
    ) - interval '{{ amendment_lookback_days }} days'
    {% endif %}

),

facts as (

    select
        numeric_facts.adsh,
        numeric_facts.tag,
        numeric_facts.taxonomy_version,
        numeric_facts.coregistrant,
        numeric_facts.segments,
        numeric_facts.period_end_date,
        numeric_facts.qtrs,
        numeric_facts.unit_of_measure,
        numeric_facts.value,
        numeric_facts.footnote,
        numeric_facts.is_instant,
        numeric_facts.is_annual,
        numeric_facts.has_segments,
        numeric_facts.source_quarter,
        submissions.cik,
        submissions.filed_date
    from {{ ref('stg_numeric') }} as numeric_facts
    join submissions
        on numeric_facts.adsh = submissions.adsh

)

select
    {{ dbt_utils.generate_surrogate_key([
        'facts.adsh',
        'facts.tag',
        'facts.taxonomy_version',
        'facts.coregistrant',
        'facts.segments',
        'facts.period_end_date',
        'facts.qtrs',
        'facts.unit_of_measure'
    ]) }}                                       as financial_fact_sk,

    dim_company.company_sk,
    dim_filing.filing_sk,
    dim_tag.tag_sk,
    filing_date.date_sk                         as filed_date_sk,

    -- The composite natural key, carried in full so the grain is readable
    -- without resolving four surrogate keys.
    facts.adsh,
    facts.tag,
    facts.taxonomy_version,
    facts.coregistrant,
    facts.segments,
    facts.period_end_date,
    facts.qtrs,
    facts.unit_of_measure,

    -- cik is a degenerate dimension here: int_restatements partitions on it,
    -- and resolving company_sk first would join 42.8m rows to reach a column
    -- that never varies within a filing.
    facts.cik,

    -- Two dates, never collapsed. period_end_date is the period the number
    -- describes; filed_date is when it became knowable.
    facts.filed_date,

    facts.value,
    facts.footnote,
    facts.is_instant,
    facts.is_annual,
    facts.has_segments,
    facts.source_quarter
from facts

-- Inner join, deliberately. A gap in the validity ranges must drop a row and
-- an overlap must duplicate one, so that assert_fact_grain_matches_staging
-- reports the defect instead of a left join concealing it as a null.
join {{ ref('dim_company') }} as dim_company
    on  dim_company.cik = facts.cik
    and facts.filed_date between dim_company.valid_from and dim_company.valid_to

join {{ ref('dim_filing') }} as dim_filing
    on dim_filing.adsh = facts.adsh

join {{ ref('dim_date') }} as filing_date
    on filing_date.date_day = facts.filed_date

-- Left join, also deliberately. dim_tag is a Type 1 dictionary snapshot; a tag
-- the current snapshot happens not to define is still a reported number and
-- must not be deleted from the fact table. Every key resolves in the loaded
-- range, so this costs nothing today and holds the grain if that changes.
left join {{ ref('dim_tag') }} as dim_tag
    on  dim_tag.tag = facts.tag
    and dim_tag.taxonomy_version = facts.taxonomy_version
