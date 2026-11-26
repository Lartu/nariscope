#!/usr/bin/env python3
"""Evaluate synthetic boundary labels and summarize a downloaded corpus."""

from __future__ import annotations

import argparse
import json
import random
from pathlib import Path

from gopher_reflow import reflow_text


LABELED = [
    ("wrapped prose", "The old road leads through the forest and eventually reaches\na small village beside the river. Travellers usually stop here\nbefore continuing north.", {1, 2}),
    ("paragraphs", "A sufficiently long paragraph line has many ordinary words here.\nIts ending stays attached.\n\nA distinct paragraph starts here.", {1}),
    ("table", "Name          Score\nAlice            10\nBob               8", set()),
    ("ASCII art", "+----------+\n|  HELLO   |\n+----------+", set()),
    ("verse", "I wandered alone\nUnder a pale moon\nHome was far away", set()),
    ("two-line status heading", " Temperature and Humidity Remote Tracking for Floodgap HQ Data Center\n updated every 10 minutes", set()),
    ("separator", "This is prose above a deliberately visible separator.\n------------------------------\nThis is prose below the visible separator.", set()),
    ("quote", "> This quoted paragraph has enough words to approach the common width\n> and it continues naturally onto another long line of quoted prose\n> before ending here.", {1, 2}),
]


def synthetic_metrics():
    tp = fp = fn = tn = 0
    details = []
    for name, text, expected in LABELED:
        result = reflow_text(text)
        actual = {d.line for d in result.decisions if d.join}
        boundaries = {d.line for d in result.decisions}
        tp += len(actual & expected); fp += len(actual - expected)
        fn += len(expected - actual); tn += len(boundaries - actual - expected)
        details.append({"case": name, "expected_joins": sorted(expected), "actual_joins": sorted(actual)})
    precision = tp / (tp + fp) if tp + fp else 1.0
    recall = tp / (tp + fn) if tp + fn else 1.0
    return {"tp": tp, "fp": fp, "fn": fn, "tn": tn,
            "precision": precision, "recall": recall,
            "f1": 2 * precision * recall / (precision + recall) if precision + recall else 0,
            "details": details}


def corpus_metrics(corpus: Path, samples: int = 8):
    manifest = json.loads((corpus / "manifest.json").read_text())
    docs = [r for r in manifest if r["ok"] and r["item_type"] == "0" and r.get("raw_file")]
    rng = random.Random(1436)
    selected = rng.sample(docs, min(samples, len(docs)))
    reviews = []
    for record in selected:
        raw = (corpus / record["raw_file"]).read_text(encoding="utf-8", errors="replace")
        rendered = reflow_text(raw)
        joined = [d for d in rendered.decisions if d.join]
        snippets = []
        lines = raw.splitlines()
        for d in joined[:3]:
            i = d.line - 1
            snippets.append({"line": d.line, "before": lines[i] + "\\n" + lines[i + 1],
                             "score": d.score, "reason": d.reason})
        reviews.append({"url": record["url"], "joined": len(joined), "sample_joins": snippets})
    return {
        "documents": len(docs),
        "bytes": sum(r["bytes"] for r in docs),
        "joined_boundaries": sum(r["joined"] for r in docs),
        "preserved_boundaries": sum(r["preserved"] for r in docs),
        "failed_requests": sum(not r["ok"] for r in manifest),
        "review_sample": reviews,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("corpus", type=Path, nargs="?")
    parser.add_argument("-o", "--output", type=Path)
    args = parser.parse_args()
    report = {"synthetic": synthetic_metrics()}
    if args.corpus:
        report["live_corpus"] = corpus_metrics(args.corpus)
    encoded = json.dumps(report, indent=2, ensure_ascii=False)
    if args.output:
        args.output.write_text(encoded + "\n", encoding="utf-8")
    print(encoded)


if __name__ == "__main__":
    main()
