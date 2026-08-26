select
    adsh,
    nullif(report, '')::int                 as report_number,
    nullif(line, '')::int                   as line_number,
    upper(trim(stmt))                       as statement_code,
    case upper(trim(stmt))
        when 'BS' then 'balance sheet'
        when 'IS' then 'income statement'
        when 'CF' then 'cash flow'
        when 'EQ' then 'equity'
        when 'CI' then 'comprehensive income'
        when 'CP' then 'cover page'
        else 'unclassified'
    end                                     as statement_name,
    (inpth = '1')                           as is_parenthetical,
    trim(tag)                               as tag,
    trim(version)                           as taxonomy_version,
    nullif(trim(plabel), '')                as presentation_label,
    source_quarter
from {{ source('raw', 'pre') }}
where adsh is not null
