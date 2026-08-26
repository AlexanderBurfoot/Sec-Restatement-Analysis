select
    adsh,
    trim(tag)                               as tag,
    trim(version)                           as taxonomy_version,
    coalesce(nullif(trim(coreg), ''), '')   as coregistrant,

    {{ yyyymmdd_to_date('ddate') }}         as period_end_date,
    nullif(qtrs, '')::int                   as qtrs,
    trim(uom)                               as unit_of_measure,
    {{ safe_numeric('value') }}             as value,
    nullif(trim(footnote), '')              as footnote,

    -- Convenience flags used all over the analysis layer.
    (qtrs = '0')                            as is_instant,
    (qtrs = '4')                            as is_annual,
    (version = adsh)                        as is_custom_tag,

    source_quarter
from {{ source('raw', 'num') }}
where adsh is not null
  and tag is not null
