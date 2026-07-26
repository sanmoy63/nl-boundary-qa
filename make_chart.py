#!/usr/bin/env python3
"""
Draw the headline chart from results/vintage_disagreement.csv.

    python code/nl_boundaries/make_chart.py

Writes docs/vintage_drift.png. Reads the CSV rather than hardcoded numbers, so the picture
always matches whatever the last pipeline run produced.
"""
from __future__ import annotations

import csv
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

HERE = Path(__file__).resolve().parent
CSV = HERE / "results" / "vintage_disagreement.csv"
OUT = HERE / "docs" / "vintage_drift.png"

TEAL = ["#0d6b78", "#3a97a2", "#a9d2d6"]     # one shade per source-map band
INK, MUTED, GRID = "#1b2430", "#5f6b78", "#e3e7ec"


def band(vintage_at_time: int) -> int:
    # colour bars by which map they were joined to
    return {2015: 0, 2020: 1, 2025: 2}.get(vintage_at_time, 0)


def load():
    years, vals, bands = [], [], []
    with open(CSV) as fh:
        for row in csv.DictReader(fh):
            years.append(int(row["obs_year"]))
            vals.append(float(row["pct_changed"]))
            bands.append(band(int(row["vintage_at_time"])))
    return years, vals, bands


def main() -> None:
    years, vals, bands = load()
    colors = [TEAL[b] for b in bands]

    plt.rcParams.update({
        "font.family": "sans-serif",
        "font.sans-serif": ["Helvetica Neue", "Helvetica", "Arial", "DejaVu Sans"],
        "axes.edgecolor": MUTED, "text.color": INK,
        "xtick.color": MUTED, "ytick.color": MUTED,
    })

    fig, ax = plt.subplots(figsize=(9.4, 5.3), dpi=200)
    fig.patch.set_facecolor("white"); ax.set_facecolor("white")
    fig.subplots_adjust(left=0.085, right=0.975, top=0.80, bottom=0.135)

    ax.bar(years, vals, width=0.74, color=colors, zorder=3)
    ax.set_axisbelow(True)
    ax.yaxis.grid(True, color=GRID, linewidth=1, zorder=0)
    ax.set_ylim(0, 50); ax.set_yticks(range(0, 51, 10))
    ax.set_yticklabels([f"{v}%" for v in range(0, 51, 10)])
    ax.set_xticks([2005, 2010, 2015, 2020, 2025])
    for s in ("top", "right", "left"):
        ax.spines[s].set_visible(False)
    ax.tick_params(length=0)

    # mark the 2025 self-check (0% by construction) so it isn't just an empty slot
    ax.scatter([2025], [0.6], color=TEAL[0], s=16, zorder=4)
    ax.annotate("2025: 0%\n(self-check)", xy=(2025, 1), xytext=(2025, 9.5),
                ha="center", fontsize=8.5, color=MUTED, linespacing=1.2)
    ax.text(2012, 47.6, "joined to 2015 map", ha="center", fontsize=9, color=TEAL[0], weight="bold")
    ax.text(2022, 22.4, "2020 map", ha="center", fontsize=9, color=TEAL[1], weight="bold")

    fig.text(0.085, 0.925, "Neighbourhood assignment drifts with boundary vintage",
             fontsize=14, weight="bold", color=INK, ha="left")
    fig.text(0.085, 0.875,
             "Share of records landing in a different neighbourhood than the 2025 map, by record year",
             fontsize=9.7, color=MUTED, ha="left")
    fig.text(0.085, 0.028,
             "44,000-point demonstration on public CBS Wijk- en Buurtkaart data "
             "(2015 · 2020 · 2025).   © CBS / Kadaster.",
             fontsize=7.7, color=MUTED, ha="left")

    OUT.parent.mkdir(exist_ok=True)
    plt.savefig(OUT, facecolor="white", dpi=200)
    print(f"wrote {OUT.relative_to(HERE)}")


if __name__ == "__main__":
    main()
