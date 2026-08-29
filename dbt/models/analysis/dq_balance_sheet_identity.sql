{{ config(materialized='table') }}

/*
  Accounting identity check: Assets = Liabilities + Equity.

  Every rule elsewhere in this report tests whether a value is present,
  plausible, or unambiguously keyed. None test whether it is *right*. This one
  does, because the balance sheet identity must hold by construction --
  a violation is a defect regardless of what the company's business looks like.

  Two forms are tested:
    (a) Assets = LiabilitiesAndStockholdersEquity  -- the reported total
    (b) Assets = Liabilities + StockholdersEquity  -- the components

  Scoping decisions that matter:

  - qtrs = 0 only. Balance sheet figures are instantaneous. Duration facts are
    income statement or cash flow and do not participate in this identity.
  - Consolidated parent figures only. Coregistrant and segments both empty.
    Segment level and subsidiary breakdowns do not balance on their own and
    including them would generate false positives at scale.
  - USD only, to avoid comparing across currencies.
  - No threshold is applied here. The gap is computed and left raw so the
    distribution can be inspected before choosing a materiality bound. A
    threshold picked before seeing the data is a guess.

  Note: where the same tag appears twice within a filing with different values.
  (DQ-03), max() selects one arbitrarily. 154 such groups exist across 42.8M
  facts, so the effect on this model is negligible, but it is not zero.
*/

with balance_sheet_facts as (

    select
        adsh,
        period_end_date,
        tag,
        value
    from {{ ref('stg_numeric') }}
    where qtrs = 0
      and unit_of_measure = 'USD'
      and coregistrant = ''
      and segments = ''
      and value is not null
      and tag in (
          'Assets',
          'Liabilities',
          'LiabilitiesAndStockholdersEquity',
          'StockholdersEquity',
          'StockholdersEquityIncludingPortionAttributableToNoncontrollingInterest'
      )

),

pivoted as (

    select
        adsh,
        period_end_date,
        max(value) filter (where tag = 'Assets')                    as assets,
        max(value) filter (where tag = 'Liabilities')               as liabilities,
        max(value) filter (where tag = 'LiabilitiesAndStockholdersEquity')
                                                                    as liabilities_and_equity,
        coalesce(
            max(value) filter (
                where tag = 'StockholdersEquityIncludingPortionAttributableToNoncontrollingInterest'
            ),
            max(value) filter (where tag = 'StockholdersEquity')
        )                                                           as equity
    from balance_sheet_facts
    group by 1, 2

),

gaps as (

    select
        p.adsh,
        p.period_end_date,
        s.cik,
        s.company_name,
        s.form_type,
        s.filer_status,
        s.filed_date,

        p.assets,
        p.liabilities,
        p.equity,
        p.liabilities_and_equity,

        -- Form (a): reported total
        (p.assets - p.liabilities_and_equity)                       as total_gap,
        case when p.assets <> 0
             then abs(p.assets - p.liabilities_and_equity) / abs(p.assets)
        end                                                         as total_pct_gap,

        -- Form (b): summed components
        (p.assets - (p.liabilities + p.equity))                     as component_gap,
        case when p.assets <> 0
             then abs(p.assets - (p.liabilities + p.equity)) / abs(p.assets)
        end                                                         as component_pct_gap

    from pivoted p
    join {{ ref('stg_submissions') }} s on s.adsh = p.adsh
    where p.assets is not null

)

select
    *,
    (liabilities_and_equity is not null)            as has_reported_total,
    (liabilities is not null and equity is not null) as has_components
from gaps
