{{ config(severity="warn") }}

{{ config(severity="warn") }}

-- qtrs is the number of quarters a value covers: 0 instant, 1 quarterly,
-- 4 annual. Long durations are legitimate for inception-to-date figures from
-- development-stage companies, but values beyond 40 quarters (10 years) are
-- defective -- the source contains durations up to 3,604 quarters, or 901 years.
select
    qtrs,
    count(*) as facts,
    round(qtrs / 4.0, 1) as implied_years
from {{ ref('stg_numeric') }}
where qtrs > 40 or qtrs < 0
group by qtrs
order by qtrs desc