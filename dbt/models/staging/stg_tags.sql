select
    trim(tag)                               as tag,
    trim(version)                           as taxonomy_version,
    (custom = '1')                          as is_custom,
    (abstract = '1')                        as is_abstract,
    nullif(trim(datatype), '')              as data_type,
    nullif(trim(iord), '')                  as instant_or_duration,
    nullif(trim(crdr), '')                  as natural_balance,
    nullif(trim(tlabel), '')                as tag_label,
    source_quarter
from {{ source('raw', 'tag') }}
where tag is not null
