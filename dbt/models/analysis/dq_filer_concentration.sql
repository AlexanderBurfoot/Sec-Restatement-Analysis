{{ config(materialized='table') }}

/*
  Concentration: are defects spread across the filer population, or produced by
  a small number of companies?

  Each rule so far has been reported as a count. A count says how much, not
  whether it is systemic. If 90% of defects come from 2% of filers, the
  remediation is "handle these filers"; if they are evenly spread, it is
  "handle this data source". Those are different conclusions and the counts
  alone do not distinguish them.

  Six rules are evaluated per filer. Two are rate based (nulls, custom tags) and
  are flagged at twice the population rate rather than at any occurrence, since
  every filer has some. Four are event-based and flagged on any occurrence,
  since each is rare enough that one instance is notable.

  The output is one row per filer with a flag per rule and a total rule count,
  which supports both the concentration question and the co occurrence question:
  do the same filers fail multiple independent checks?
*/

with population_rates as (

    select
        (count(*) filter (where value is null))::numeric
            / nullif(count(*), 0)                       as null_rate
    from {{ ref('stg_numeric') }}

),

filer_base as (

    -- Most recent name per filer, so a renamed company appears once.
    select distinct on (cik)
        cik,
        company_name,
        filer_status
    from {{ ref('stg_submissions') }}
    order by cik, filed_date desc

),

per_filer_facts as (

    select
        s.cik,
        count(*)                                        as facts,
        count(*) filter (where n.value is null)         as null_facts,
        count(*) filter (where n.qtrs > 40 or n.qtrs < 0) as bad_duration_facts,
        count(*) filter (where t.is_custom)             as custom_facts
    from {{ ref('stg_numeric') }} n
    join {{ ref('stg_submissions') }} s on s.adsh = n.adsh
    left join {{ ref('stg_tags') }} t
           on t.tag = n.tag and t.taxonomy_version = n.taxonomy_version
    group by 1

),

conflicting_dupes as (

    select distinct s.cik
    from (
        select adsh
        from {{ ref('stg_numeric') }}
        group by adsh, tag, taxonomy_version, coregistrant,
                 segments, period_end_date, qtrs, unit_of_measure
        having count(*) > 1 and count(distinct value) > 1
    ) d
    join {{ ref('stg_submissions') }} s on s.adsh = d.adsh

),

date_errors as (

    select distinct cik
    from {{ ref('stg_submissions') }}
    where filed_date < period_end_date

),

balance_violations as (

    select distinct cik
    from {{ ref('dq_balance_sheet_identity') }}
    where has_reported_total
      and total_pct_gap > 0.001        -- 0.1%, per the §1.10 threshold

),

flagged as (

    select
        f.cik,
        f.company_name,
        f.filer_status,
        p.facts,

        round(100.0 * p.null_facts / nullif(p.facts, 0), 2)     as pct_null,
        round(100.0 * p.custom_facts / nullif(p.facts, 0), 2)   as pct_custom,
        p.bad_duration_facts,

        -- rate-based rules: flagged at twice the population rate
        (p.null_facts::numeric / nullif(p.facts, 0)
            > 2 * (select null_rate from population_rates))     as flag_null_heavy,
        (p.custom_facts::numeric / nullif(p.facts, 0) > 0.20)   as flag_custom_heavy,

        -- event-based rules: flagged on any occurrence
        (p.bad_duration_facts > 0)                              as flag_bad_duration,
        (cd.cik is not null)                                    as flag_conflicting_dupes,
        (de.cik is not null)                                    as flag_date_error,
        (bv.cik is not null)                                    as flag_balance_violation

    from filer_base f
    join per_filer_facts p on p.cik = f.cik
    left join conflicting_dupes cd  on cd.cik = f.cik
    left join date_errors de        on de.cik = f.cik
    left join balance_violations bv on bv.cik = f.cik

)

select
    *,
    (flag_null_heavy::int
     + flag_custom_heavy::int
     + flag_bad_duration::int
     + flag_conflicting_dupes::int
     + flag_date_error::int
     + flag_balance_violation::int)                             as rules_failed
from flagged
