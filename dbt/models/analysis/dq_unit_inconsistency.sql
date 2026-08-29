{{ config(materialized='table') }}

/*
  Tags reported under more than one unit of measure.

  This is NOT primarily a data quality defect. Most multi-unit tags come from
  the IFRS taxonomy, used by foreign private issuers who report in their home
  currency -- Assets appears in 43 currencies because the filers are Japanese,
  Brazilian, Korean and so on. That is correct reporting.

  What it does mean: these tags cannot be aggregated across filers without FX
  conversion at an appropriate rate and date. A naive sum over Assets adds
  yen to euros. That is a comparability constraint on any downstream analysis,
  and it is worth quantifying for that reason rather than as a defect count.

  The genuine errors are separable: a tag carrying a non currency unit where a
  currency is expected (a ratio tagged as revenue) is a real tagging mistake.
  The `has_non_currency_unit` flag isolates those.
*/

with unit_usage as (

    select
        tag,
        unit_of_measure,
        count(*) as facts
    from {{ ref('stg_numeric') }}
    where value is not null
    group by 1, 2

),

per_tag as (

    select
        tag,
        count(distinct unit_of_measure)                     as distinct_units,
        sum(facts)                                          as total_facts,
        string_agg(distinct unit_of_measure, ', ' order by unit_of_measure)
                                                            as units_used,

        -- ISO 4217 codes are three uppercase letters. Anything else in a tag
        -- that otherwise carries currencies is the suspicious case.
        count(distinct unit_of_measure)
            filter (where unit_of_measure ~ '^[A-Z]{3}$')   as currency_units,
        count(distinct unit_of_measure)
            filter (where unit_of_measure !~ '^[A-Z]{3}$')  as non_currency_units,

        sum(facts) filter (where unit_of_measure !~ '^[A-Z]{3}$')
                                                            as non_currency_facts

    from unit_usage
    group by 1
    having count(distinct unit_of_measure) > 1

)

select
    tag,
    distinct_units,
    currency_units,
    non_currency_units,
    total_facts,
    non_currency_facts,

    -- A tag used with several currencies AND a non-currency unit is where the
    -- real tagging errors live: e.g. Revenue reported with unit 'pure'.
    (currency_units > 1 and non_currency_units > 0) as has_suspect_unit_mix,

    units_used
from per_tag
order by has_suspect_unit_mix desc, non_currency_facts desc, distinct_units desc
