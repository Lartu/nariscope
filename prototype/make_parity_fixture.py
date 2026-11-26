"""Generate the JSON input for the Swift renderer parity test."""

import argparse
import json
from pathlib import Path

from gopher_reflow import decode_text
from render_corpus_html import render_document


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("corpus", type=Path)
    parser.add_argument("-o", "--output", type=Path, required=True)
    args = parser.parse_args()

    manifest = json.loads((args.corpus / "manifest.json").read_text(encoding="utf-8"))
    pages = []
    for entry in manifest:
        if not (entry["ok"] and entry["item_type"] == "0" and entry.get("raw_file")):
            continue
        raw = args.corpus / entry["raw_file"]
        source = decode_text(raw.read_bytes()).replace("\r\n", "\n").replace("\r", "\n")
        pages.append({"name": raw.name, "source": source, "expected": render_document(source)})
    if not pages:
        parser.error("the corpus contains no downloaded text documents")

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(pages, ensure_ascii=False), encoding="utf-8")
    print(f"Wrote {len(pages)} reference pages to {args.output}")


if __name__ == "__main__":
    main()
