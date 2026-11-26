# Conservative Gopher prose reflow

`gopher_reflow.py` implements an explainable heuristic for joining soft-wrapped
prose without flattening menus, tables, ASCII art, lists, quotations, or blank
paragraph boundaries. It uses only Python's standard library.

From the repository root:

```sh
python3 -m unittest discover -s prototype -v
python3 prototype/gopher_reflow.py render page.txt --explain
python3 prototype/gopher_reflow.py crawl -o work/corpus --max-documents 40
python3 prototype/render_corpus_html.py work/corpus outputs/html-reader
python3 prototype/evaluate.py work/corpus -o work/evaluation.json
```

The crawler speaks Gopher directly over TCP, visits only the configured seed
hosts by default, follows only menu and text entries, caps responses at 2 MB,
and writes a `manifest.json`. Raw and `.reflowed.txt` files are kept side by
side so every decision can be inspected.

Real pages do not contain labels for intentional versus automatic breaks, so
live-corpus counts are diagnostics rather than accuracy claims. The unit tests
provide labeled cases; the companion `evaluate.py` generates the corpus report
and review samples.
