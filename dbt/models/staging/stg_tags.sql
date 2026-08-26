-- tag.txt is a FULL dictionary snapshot in every quarterly ZIP, not incremental
-- data. The same tag appears once per quarter loaded. Keep the most recent
-- definition per (tag, version).
select distinct on (trim(tag), trim(version))
    trim(tag)                   as tag,
    trim(version)               as taxonomy_version,
    (custom = '1')              as is_custom,
    (abstract = '1')            as is_abstract,
    nullif(trim(datatype), '')  as data_type,
    nullif(trim(iord), '')      as instant_or_duration,
    nullif(trim(crdr), '')      as natural_balance,
    nullif(trim(tlabel), '')    as tag_label,
    source_quarter              as last_seen_quarter
from {{ source('raw', 'tag') }}
where tag is not null
order by trim(tag), trim(version), source_quarter desc
