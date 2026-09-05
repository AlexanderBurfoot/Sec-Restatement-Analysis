"""
Render the charts embedded in the README.

One chart today: the restatement rate by total-assets decile. It exists because
the shape is not the expected one. The rate rises to the second decile, falls
monotonically to the ninth, then turns back up at the largest, which a
regulatory filer-status banding cannot show because one band spans the whole
reversal.

Aggregation stays in SQL. This script queries the finished analysis table and
does nothing but draw it.
"""

import os
from pathlib import Path

import matplotlib

matplotlib.use("Agg")

import matplotlib.pyplot as plt  # noqa: E402  (backend must be set first)
import psycopg  # noqa: E402
from dotenv import load_dotenv  # noqa: E402

load_dotenv()

OUT_DIR = Path(__file__).resolve().parents[1] / "docs" / "img"
SIZE_CHART_PATH = OUT_DIR / "restatement_rate_by_size.png"

FIGURE_INCHES = (9.0, 4.5)
FIGURE_DPI = 150
BAR_COLOUR = "#4c72b0"
REVERSAL_BAR_COLOUR = "#c44e52"
LABEL_OFFSET_POINTS = 3
Y_HEADROOM_FACTOR = 1.18

# The decile where the monotone decline reverses. Named rather than inlined
# because it is the whole point of the chart.
REVERSAL_DECILE = 10

# band_sort carries the decile number on these rows. Companies with no
# consolidated USD assets are banded 'unclassified' and sorted last; they are
# not a decile and are excluded rather than drawn as an eleventh bar.
UNCLASSIFIED_BAND = "unclassified"

DECILE_RATE_QUERY = """
    select
        band_sort as assets_decile,
        pct_of_revisable_restated
    from public_analysis.rst_by_filer_size
    where size_basis = 'assets_decile'
      and size_band is distinct from %(unclassified)s
    order by band_sort
"""


def conn_string() -> str:
    return (
        f"host={os.getenv('POSTGRES_HOST', 'localhost')} "
        f"port={os.getenv('POSTGRES_PORT', '5433')} "
        f"dbname={os.getenv('POSTGRES_DB', 'sec')} "
        f"user={os.getenv('POSTGRES_USER', 'sec')} "
        f"password={os.getenv('POSTGRES_PASSWORD', 'sec')}"
    )


def fetch_decile_rates() -> list[tuple[int, float]]:
    with psycopg.connect(conn_string()) as conn:
        with conn.cursor() as cur:
            cur.execute(
                DECILE_RATE_QUERY, {"unclassified": UNCLASSIFIED_BAND}
            )
            return [(int(d), float(r)) for d, r in cur.fetchall()]


def draw_decile_chart(rates: list[tuple[int, float]], path: Path) -> None:
    deciles = [d for d, _ in rates]
    values = [r for _, r in rates]
    colours = [
        REVERSAL_BAR_COLOUR if d == REVERSAL_DECILE else BAR_COLOUR
        for d in deciles
    ]

    figure, axes = plt.subplots(figsize=FIGURE_INCHES, dpi=FIGURE_DPI)
    bars = axes.bar(deciles, values, color=colours)

    for bar, value in zip(bars, values):
        axes.annotate(
            f"{value:.2f}%",
            xy=(bar.get_x() + bar.get_width() / 2, value),
            xytext=(0, LABEL_OFFSET_POINTS),
            textcoords="offset points",
            ha="center",
            va="bottom",
            fontsize=9,
        )

    axes.set_title(
        "Restatement rate by total-assets decile",
        fontsize=13,
        pad=12,
        loc="left",
    )
    axes.set_xlabel("Total assets decile  (1 = smallest, 10 = largest)")
    axes.set_ylabel("Share of revisable facts restated")
    axes.set_xticks(deciles)
    axes.set_ylim(0, max(values) * Y_HEADROOM_FACTOR)
    axes.yaxis.set_major_formatter(lambda v, _: f"{v:.0f}%")
    axes.spines["top"].set_visible(False)
    axes.spines["right"].set_visible(False)
    axes.grid(axis="y", linewidth=0.4, alpha=0.4)
    axes.set_axisbelow(True)

    figure.tight_layout()
    path.parent.mkdir(parents=True, exist_ok=True)
    figure.savefig(path)
    plt.close(figure)


def main() -> int:
    rates = fetch_decile_rates()
    draw_decile_chart(rates, SIZE_CHART_PATH)
    print(f"wrote {SIZE_CHART_PATH}")
    print(
        "  peak {peak_rate:.2f}% at decile {peak}, "
        "trough {trough_rate:.2f}% at decile {trough}, "
        "{last_rate:.2f}% at decile {last}".format(
            peak=max(rates, key=lambda r: r[1])[0],
            peak_rate=max(rates, key=lambda r: r[1])[1],
            trough=min(rates, key=lambda r: r[1])[0],
            trough_rate=min(rates, key=lambda r: r[1])[1],
            last=rates[-1][0],
            last_rate=rates[-1][1],
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
