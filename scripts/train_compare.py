"""Compare a point-in-time feature table against a leaky one.

Fits the same logistic regression twice, once on feat_filing_pit and once on
feat_filing_naive. The two tables carry the same filings, the same label and the
same five features; they differ only in whether the prior-restatement count and
the sector base rate were computed from what was knowable on the filing date or
from the whole loaded range.

The model is deliberately trivial and is not the deliverable. It is standardised
inputs into scikit-learn's default logistic regression, with no tuning, no
regularisation search, no class weighting and no feature engineering beyond what
the SQL already did. A better model would raise both numbers. The point is the
distance between them, which is what the leak is worth on unseen data.

The split is by date, never at random. These are panel data: the same company
files every quarter, so a random split puts a company's 2024 filings in train and
its 2023 filings in test, and the model recognises the company rather than
predicting anything. Training ends where 2025 begins.

Two training regimes are reported. The second exists because the point-in-time
sector rate has no history to read during the first months of the loaded range
and reads zero there, while those same early filings are annual-report heavy and
restate more often than average. The model fits a negative coefficient to that
confound and carries it into a test period where the relationship runs the other
way. Dropping those rows from training tests whether the gap survives without
that artefact. The filter is applied to both feature sets identically and never
to the test set, so the two models stay comparable and the test population is the
same in every row of the output.

Usage:
    python scripts/train_compare.py
"""

from __future__ import annotations

import datetime as dt
import os

import numpy as np
import psycopg
from dotenv import load_dotenv
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import roc_auc_score
from sklearn.pipeline import make_pipeline
from sklearn.preprocessing import StandardScaler

load_dotenv()

POINT_IN_TIME = "point-in-time"
NAIVE = "naive"

# The two tables under comparison. Same rows, same label, same feature names.
RELATIONS = {
    POINT_IN_TIME: "public_analysis.feat_filing_pit",
    NAIVE: "public_analysis.feat_filing_naive",
}

# Order is fixed so the coefficient report lines up with the column list.
FEATURE_COLUMNS = (
    "filing_lag_days",
    "is_large_accelerated_filer",
    "is_accelerated_filer",
    "is_non_accelerated_filer",
    "custom_tag_share",
    "prior_restatement_count",
    "sector_restatement_rate",
)

# Read alongside the features but never fitted on. How much resolved history the
# sector rate was computed over, which is what identifies the warm-up rows.
HISTORY_COLUMN = "sector_prior_resolved_filings"

# Filings before this date train the model; filings on or after it test it.
TRAIN_END_DATE = dt.date(2025, 1, 1)

# scikit-learn defaults, stated rather than tuned. max_iter is raised only
# because lbfgs does not converge on seven standardised features in 100 steps.
SOLVER = "lbfgs"
MAX_ITERATIONS = 1000
INVERSE_REGULARISATION = 1.0


def conn_string() -> str:
    """Same connection convention as load_raw.py and checksum.py, read from .env."""
    return (
        f"host={os.getenv('POSTGRES_HOST', 'localhost')} "
        f"port={os.getenv('POSTGRES_PORT', '5433')} "
        f"dbname={os.getenv('POSTGRES_DB', 'sec')} "
        f"user={os.getenv('POSTGRES_USER', 'sec')} "
        f"password={os.getenv('POSTGRES_PASSWORD', 'sec')}"
    )


def load_feature_table(connection: psycopg.Connection, relation: str) -> dict:
    """Read one feature table into arrays, ordered by accession number.

    The ordering is what lets the two tables be compared row by row. No
    aggregation happens here: the SQL has already done all of it.
    """
    columns = ", ".join(FEATURE_COLUMNS)
    query = f"""
        select adsh, filed_date, was_restated, {HISTORY_COLUMN}, {columns}
        from {relation}
        order by adsh
    """

    with connection.cursor() as cursor:
        cursor.execute(query)
        rows = cursor.fetchall()

    return {
        "adsh": np.array([row[0] for row in rows]),
        "filed_date": np.array([row[1] for row in rows]),
        "label": np.array([bool(row[2]) for row in rows], dtype=int),
        "sector_history": np.array([int(row[3]) for row in rows]),
        "features": np.array(
            [[float(value) for value in row[4:]] for row in rows], dtype=float
        ),
    }


def assert_comparable(left: dict, right: dict) -> None:
    """Fail loudly unless the two tables differ only in feature values.

    A difference in population or label would make the AUC gap meaningless: the
    two models would be answering different questions rather than answering the
    same one with different information.
    """
    if not np.array_equal(left["adsh"], right["adsh"]):
        raise ValueError("feature tables cover different filings")
    if not np.array_equal(left["label"], right["label"]):
        raise ValueError("feature tables disagree on the label")


def select_rows(table: dict, keep: np.ndarray) -> dict:
    """Subset every array in a table by the same boolean mask."""
    return {key: value[keep] for key, value in table.items()}


def split_by_date(table: dict) -> tuple[dict, dict]:
    """Partition into train and test on filed_date, with no shuffling."""
    is_train = table["filed_date"] < TRAIN_END_DATE
    return select_rows(table, is_train), select_rows(table, ~is_train)


def fit_and_score(train: dict, test: dict) -> dict:
    """Fit the model on train, score both splits, return AUCs and coefficients."""
    model = make_pipeline(
        StandardScaler(),
        LogisticRegression(
            solver=SOLVER, max_iter=MAX_ITERATIONS, C=INVERSE_REGULARISATION
        ),
    )
    model.fit(train["features"], train["label"])

    return {
        "n_train": len(train["label"]),
        "train_auc": roc_auc_score(
            train["label"], model.predict_proba(train["features"])[:, 1]
        ),
        "test_auc": roc_auc_score(
            test["label"], model.predict_proba(test["features"])[:, 1]
        ),
        "coefficients": model[-1].coef_[0],
    }


def univariate_test_auc(test: dict) -> np.ndarray:
    """Test AUC of each feature used alone, as a raw score.

    Diagnostic, not a model. It attributes the gap between the two fitted models
    to individual features without refitting anything. A feature that ranks
    filings backwards is reported by its mirrored AUC, so every value reads as
    discriminating power regardless of sign.
    """
    scores = []
    for column in test["features"].T:
        auc = roc_auc_score(test["label"], column)
        scores.append(max(auc, 1.0 - auc))
    return np.array(scores)


def print_population(train: dict, test: dict) -> None:
    """Population and base rates, identical for both feature tables."""
    print("population")
    print(f"  {'split':<14}{'filings':>10}{'restated':>10}{'rate':>10}")
    for name, split in (("train", train), ("test", test)):
        n_rows = len(split["label"])
        n_positive = int(split["label"].sum())
        print(
            f"  {name:<14}{n_rows:>10,}{n_positive:>10,}"
            f"{n_positive / n_rows:>10.2%}"
        )
    print(
        f"  train  filed <  {TRAIN_END_DATE}"
        f"   ({train['filed_date'].min()} .. {train['filed_date'].max()})"
    )
    print(
        f"  test   filed >= {TRAIN_END_DATE}"
        f"   ({test['filed_date'].min()} .. {test['filed_date'].max()})"
    )
    print()


def print_regime(regime_name: str, results: dict[str, dict]) -> None:
    """One block of the headline table: AUC per feature set, and the gap."""
    n_train = results[POINT_IN_TIME]["n_train"]
    print(f"  {regime_name}, trained on {n_train:,} filings")
    print(f"    {'feature set':<16}{'train':>10}{'test':>10}")
    for label, result in results.items():
        print(f"    {label:<16}{result['train_auc']:>10.4f}{result['test_auc']:>10.4f}")
    print(
        f"    {'gap':<16}"
        f"{results[NAIVE]['train_auc'] - results[POINT_IN_TIME]['train_auc']:>10.4f}"
        f"{results[NAIVE]['test_auc'] - results[POINT_IN_TIME]['test_auc']:>10.4f}"
    )
    print()


def print_features(results: dict[str, dict], univariate: dict[str, np.ndarray]) -> None:
    """Per-feature coefficients and standalone test AUC, side by side.

    Coefficients are on standardised inputs, so they are comparable to each other
    within a column but are not odds ratios on the original units.
    """
    print("per feature: fitted coefficient (standardised) and standalone test AUC")
    header = f"  {'feature':<30}"
    for label in results:
        header += f"{label + ' coef':>21}{label + ' auc':>20}"
    print(header)

    for position, feature in enumerate(FEATURE_COLUMNS):
        line = f"  {feature:<30}"
        for label in results:
            line += (
                f"{results[label]['coefficients'][position]:>21.4f}"
                f"{univariate[label][position]:>20.4f}"
            )
        print(line)
    print()


def run_regime(tables: dict[str, dict], keep_train: np.ndarray) -> dict[str, dict]:
    """Fit both feature sets over the same training rows and the same test set."""
    results = {}
    for label, table in tables.items():
        train, test = split_by_date(table)
        results[label] = fit_and_score(select_rows(train, keep_train), test)
    return results


def main() -> int:
    with psycopg.connect(conn_string()) as connection:
        tables = {
            label: load_feature_table(connection, relation)
            for label, relation in RELATIONS.items()
        }

    assert_comparable(tables[POINT_IN_TIME], tables[NAIVE])

    # The warm-up mask is read from the point-in-time table, because it is that
    # table's feature that has no history to read. It is applied to both.
    train_rows, test_rows = split_by_date(tables[POINT_IN_TIME])
    has_sector_history = train_rows["sector_history"] > 0
    all_rows = np.ones(len(train_rows["label"]), dtype=bool)

    regimes = {
        "all training rows": all_rows,
        "warm-up rows dropped": has_sector_history,
    }
    results_by_regime = {
        name: run_regime(tables, keep) for name, keep in regimes.items()
    }

    print()
    print_population(train_rows, test_rows)

    print("area under the ROC curve")
    for name, results in results_by_regime.items():
        print_regime(name, results)

    headline = results_by_regime["all training rows"]
    print_features(
        headline,
        {
            label: univariate_test_auc(split_by_date(table)[1])
            for label, table in tables.items()
        },
    )

    print("the deliverable, as a range over the two training regimes:")
    for name, results in results_by_regime.items():
        gap = results[NAIVE]["test_auc"] - results[POINT_IN_TIME]["test_auc"]
        print(f"  {name:<24}{gap:>8.4f}")
    print("  test AUC that came from after the filing date and would not have")
    print("  existed at prediction time.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
