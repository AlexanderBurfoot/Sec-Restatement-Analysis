select
    adsh,
    cik::bigint                             as cik,
    trim(name)                              as company_name,
    nullif(trim(sic), '')                   as sic_code,
    nullif(trim(countryba), '')             as business_country,
    nullif(trim(stprba), '')                as business_state,
    nullif(trim(countryinc), '')            as incorporation_country,
    nullif(trim(stprinc), '')               as incorporation_state,
    nullif(trim(former), '')                as former_name,
    nullif(trim(afs), '')                   as filer_status,
    (wksi = '1')                            as is_well_known_issuer,

    -- fye is MMDD with no year. Do NOT cast to a date.
    nullif(trim(fye), '')                   as fiscal_year_end_mmdd,

    upper(trim(form))                       as form_type,
    (form like '%/A')                       as is_amendment,

    {{ yyyymmdd_to_date('period') }}        as period_end_date,
    nullif(fy, '')::int                     as fiscal_year,
    nullif(trim(fp), '')                    as fiscal_period,

    -- The knowability date. Everything in this project turns on it.
    {{ yyyymmdd_to_date('filed') }}         as filed_date,

    (prevrpt = '1')                         as was_later_amended,
    (detail = '1')                          as has_footnote_detail,
    nullif(nciks, '')::int                  as n_ciks,

    -- Days between period end and publication. The window during which the
    -- number was not knowable.
    ({{ yyyymmdd_to_date('filed') }} - {{ yyyymmdd_to_date('period') }})
                                            as filing_lag_days,

    source_quarter
from {{ source('raw', 'sub') }}
where adsh is not null
