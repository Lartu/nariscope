"""Export a saved Gopher corpus as an offline HTML reader."""

import argparse
import json
import re
from collections import defaultdict
from html import escape
from pathlib import Path
from statistics import median
from urllib.parse import urlsplit

from gopher_reflow import _prefix_and_body, decode_text


STYLE = """+:root { color-scheme: light dark; --paper: #fcfaf4; --ink: #242d2a;
  --line: #d8d9ce; --accent: #215d50; --panel: #efeee5; }
@media (prefers-color-scheme: dark) {
  :root { --paper: #181e1d; --ink: #ebede3; --line: #495451;
    --accent: #9cdbca; --panel: #222b29; }
}
* { box-sizing: border-box; }
body { margin: 0; background: var(--paper); color: var(--ink);
  font: 1.1rem/1.65 system-ui, sans-serif; }
main { max-width: 52rem; margin: auto; padding: 2.5rem clamp(1rem, 5vw, 3rem) 4rem; }
h1 { font: bold clamp(2rem, 5vw, 3.2rem)/1.09 Georgia, serif; margin: 1rem 0; }
h2 { font-size: 1.2rem; margin-top: 1.6em; }
p, h1, h2, code, li { overflow-wrap: anywhere; }
a { color: var(--accent); text-underline-offset: .18em; }
nav { display: flex; flex-wrap: wrap; gap: .35rem 1.2rem; }
footer { margin-top: 2rem; border-top: 1px solid var(--line); padding-top: 1rem; }
.source { font-size: .88rem; }
article { font: 1.18rem/1.7 Georgia, serif; }
blockquote { border-left: 3px solid var(--line); margin: 1em 0; padding-left: 1em; }
pre { max-width: 100%; overflow: auto; background: var(--panel); color: var(--ink);
  border: 1px solid var(--line); border-radius: .4rem; padding: 1em;
  font: .88rem/1.35 ui-monospace, SFMono-Regular, Consolas, monospace; tab-size: 8; }
summary { cursor: pointer; color: var(--accent); width: fit-content; }
details[open] + article { display: none; }
ul { padding-inline-start: 1.5em; }
"""

UNDERLINE = re.compile(r"\s*(?:={3,}|-{3,})\s*")
RULE = re.compile(r"[-_=*~]{4,}")
COLUMN_GAP = re.compile(r"(?<=\S) {3,}(?=\S)")
ART_MARKS = re.compile(r"[|_\\/@#~=<>^*+]")
RULER = re.compile(r"[-_=+| ]{8,}")
NETWORK_TOKEN = re.compile(r"[\w.*:/-]+")
ROW_TIMESTAMP = re.compile(
    r"^\s*(?:(?:[A-Z][a-z]{2} )?[A-Z][a-z]{2} +\d{1,2} \d{2}:\d{2}:\d{2}"
    r"|\d{1,4}[-/]\d{1,2}[-/]\d{1,4}[ T]+\d{2}:\d{2}|\d{2}:\d{2}:\d{2})\b"
)
WORD = re.compile(r"[^\W\d_]+(?:['’][^\W\d_]+)*", re.UNICODE)
SOURCE_BLOCK = re.compile(
    r"^[ \t]*<(html|svg|rss)\b[^>]*>[^\n]*\n.*?^[ \t]*</\1>[ \t]*$"
    r"|^[ \t]*(`{3,}|~{3,})[^\n]*\n.*?^[ \t]*\2[ \t]*$",
    re.IGNORECASE | re.MULTILINE | re.DOTALL,
)
METADATA = re.compile(r"^(?:last )?updated (?:every\b|on\b|\d)", re.IGNORECASE)


def preformatted(source):
    # The HTML parser strips an initial newline immediately after a <pre> tag.
    return f'<pre tabindex="0">\n{escape(source)}</pre>'


def layout_rows(lines):
    expanded = [line.expandtabs() for line in lines]
    gaps = [{m.end() for m in COLUMN_GAP.finditer(line)} for line in expanded]
    timestamps = [bool(ROW_TIMESTAMP.match(line)) for line in lines]
    art = []
    drawing_edges = []
    for line in lines:
        visible = "".join(line.split())
        marks = len(ART_MARKS.findall(visible))
        symbols = sum(not char.isalnum() for char in visible)
        network = NETWORK_TOKEN.fullmatch(line.strip()) and any(c.isdigit() for c in visible)
        art.append(bool(visible) and not network and (
            (marks >= 2 and symbols / len(visible) >= .55)
            or bool(re.search(r"[|_\\/@#~=<>^*+]{4,}", line))
        ))
        drawing_edges.append(bool(visible) and not network and symbols >= 2
                             and symbols / len(visible) >= .55
                             and not re.search(r"[A-Za-z]{3,}", visible))

    protected = set()
    picture_rows = set()
    for i, line in enumerate(expanded):
        neighbours = [j for j in range(max(0, i - 2), min(len(lines), i + 3))
                      if j != i and all(s.strip() for s in lines[min(i, j):max(i, j) + 1])]
        matches = sum(bool(gaps[i] & gaps[j]) for j in neighbours)
        wide_gap = any(m.end() - m.start() >= 6 for m in COLUMN_GAP.finditer(line))
        # Sentence justification inserts small gaps at shifting positions.
        # Tables repeatedly start a field at the same display column.
        table = matches >= 2 or (matches >= 1 and wide_gap)
        picture = art[i] and any(art[j] for j in neighbours)
        log = timestamps[i] and any(timestamps[j] for j in neighbours)
        if picture:
            picture_rows.add(i)
        if table or picture or log:
            protected.add(i)
    # Continue an outline through sparse rows at the top or bottom of a drawing.
    for start in picture_rows:
        for step in (-1, 1):
            i = start + step
            while 0 <= i < len(lines) and drawing_edges[i] and i not in picture_rows:
                protected.add(i)
                i += step
    # Restore chart rulers and rows with a missing cell between confident rows.
    for i in range(1, len(lines) - 1):
        if i - 1 in protected and i + 1 in protected and lines[i].strip():
            protected.add(i)
    for i in sorted(protected):
        # A header may have a blank line above the data or a rule under it.
        for j in range(i - 1, max(-1, i - 5), -1):
            line = expanded[j].strip()
            if not line:
                if j == i - 1:
                    continue
                break
            ruler = RULER.fullmatch(line) or (
                line.startswith("|") and re.fullmatch(r"\|[\d ]{6,}", line)
            )
            header = gaps[j] and any(abs(a - b) <= 2 for a in gaps[j] for b in gaps[i])
            if ruler or header:
                protected.update(range(j, i))
                if ruler and j and gaps[j - 1] and not expanded[j - 1].strip().endswith("."):
                    protected.add(j - 1)
            else:
                break
    return protected


def render_document(source):
    if re.match(r"\s*(?:<\?xml\b|%rec:\s)", source, re.IGNORECASE):
        return preformatted(source)
    lines = source.split("\n")
    protected = layout_rows(lines)
    offset = 0
    row = 0
    for block in SOURCE_BLOCK.finditer(source):
        row += source.count("\n", offset, block.start())
        length = block.group().count("\n")
        protected.update(range(row, row + length + 1))
        offset = block.end()
        row += length

    headings = {}
    for i, line in enumerate(lines[:-1]):
        if (line.strip() and len(line.strip()) <= 85 and i not in protected
                and i + 1 not in protected and UNDERLINE.fullmatch(lines[i + 1])):
            headings[i] = i + 2

    sections = []
    i = 0
    while i < len(lines):
        if i in headings:
            sections.append(f"<h2>{escape(lines[i].strip())}</h2>")
            i = headings[i]
        elif i in protected:
            end = i + 1
            while end in protected:
                end += 1
            sections.append(preformatted("\n".join(lines[i:end])))
            i = end
        elif not lines[i].strip():
            i += 1
        elif RULE.fullmatch(lines[i].strip()):
            sections.append("<hr>")
            i += 1
        else:
            end = i + 1
            while (end < len(lines) and lines[end].strip()
                   and end not in protected and end not in headings
                   and not RULE.fullmatch(lines[end].strip())):
                end += 1
            block = render_prose(lines[i:end])
            sections.append(block)
            i = end
    return "\n".join(sections)


def prose_joins(lines, parsed):
    widths = [len(line.rstrip().expandtabs()) for line in lines]
    words = [WORD.findall(body) for _, _, body in parsed]
    anchors = [width for width, row in zip(widths, words) if len(row) >= 6]
    width = median(sorted(anchors)[len(anchors) // 2:]) if anchors else 0
    joins = set()
    for i, ((kind, prefix, body), (next_kind, next_prefix, following)) in enumerate(
        zip(parsed, parsed[1:])
    ):
        if len(words[i]) < 5 or not words[i + 1] or widths[i] < 30:
            continue
        if next_kind == "list" or (kind == "quote") != (next_kind == "quote"):
            continue
        if METADATA.match(following.strip()):
            continue
        if kind == "quote" and prefix.count(">") != next_prefix.count(">"):
            continue
        if not body.strip() or not following.strip() or body.isupper() or following.isupper():
            continue
        continuation = following.lstrip(' "\'“‘([«')[:1].islower()
        terminal = bool(re.search(r"""[.!?]["'”’)]?\s*$""", body))
        near_margin = widths[i] >= width - 9 and width >= 36
        same_margin = abs(len(prefix.expandtabs()) - len(next_prefix.expandtabs())) <= 2
        if kind == "list":
            same_margin = len(next_prefix.expandtabs()) >= len(prefix.expandtabs())
        if continuation and not terminal and (near_margin or same_margin and widths[i] >= 40):
            joins.add(i + 1)
        elif near_margin and len(anchors) >= 2 and same_margin:
            next_word = following.split()[0]
            if not terminal or widths[i] + 1 + len(next_word) > width:
                joins.add(i + 1)
    return joins


def render_prose(lines):
    parsed = [_prefix_and_body(line) for line in lines]
    joined = prose_joins(lines, parsed)
    sections = []
    group = []
    for i, (line, (kind, _, body)) in enumerate(zip(lines, parsed), 1):
        group.append((kind, line.strip(), body.strip()))
        if i in joined:
            continue
        first_kind, first_line, first_body = group[0]
        first = first_body if first_kind == "quote" else first_line
        contents = escape(" ".join(" ".join([first] + [body for _, _, body in group[1:]]).split()))
        sections.append((first_kind, contents))
        group.clear()

    result = []
    i = 0
    while i < len(sections):
        kind, value = sections[i]
        end = i + 1
        while end < len(sections) and sections[end][0] == kind:
            end += 1
        values = [value for _, value in sections[i:end]]
        if kind == "list" and all(re.match(r"[-*+] ", value) for value in values):
            result.append("<ul>" + "".join(f"<li>{value[2:]}</li>" for value in values) + "</ul>")
        else:
            contents = "<br>\n".join(values)
            paragraph = f"<p>{contents}</p>"
            result.append(f"<blockquote>{paragraph}</blockquote>" if kind == "quote" else paragraph)
        i = end
    return "\n".join(result)


def page(title, body):
    return f"""<!doctype html>
<html lang="en">
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{escape(title)}</title>
<link rel="stylesheet" href="reader.css">
<main>
{body}
</main>
</html>
"""


def export(corpus, output):
    manifest = json.loads((corpus / "manifest.json").read_text(encoding="utf-8"))
    documents = []
    for entry in manifest:
        if not (entry["ok"] and entry["item_type"] == "0" and entry.get("raw_file")):
            continue
        raw_path = corpus / entry["raw_file"]
        number, _, label = raw_path.stem.split("_", 2)
        url = entry["url"]
        parts = urlsplit(url)
        title = label.replace("_", " ")
        documents.append((f"{number}.html", title, parts.hostname, url, raw_path))

    output.mkdir(parents=True, exist_ok=True)
    (output / "reader.css").write_text(STYLE, encoding="utf-8")
    sites = defaultdict(list)
    for i, (name, title, host, url, raw_path) in enumerate(documents):
        source = decode_text(raw_path.read_bytes()).replace("\r\n", "\n").replace("\r", "\n")
        rendered = render_document(source)
        links = ['<a href="index.html">All pages</a>']
        if i:
            links.append(f'<a href="{documents[i - 1][0]}" rel="prev">Previous page</a>')
        if i + 1 < len(documents):
            links.append(f'<a href="{documents[i + 1][0]}" rel="next">Next page</a>')
        contents = f"""<nav aria-label="Corpus">{links[0]}</nav>
<h1>{escape(title)}</h1>
<p class="source"><code>{escape(url)}</code></p>
<details><summary>Original layout</summary>{preformatted(source)}</details>
<article>
{rendered}
</article>
<footer><nav aria-label="More pages">{"".join(links)}</nav></footer>"""
        (output / name).write_text(page(title, contents), encoding="utf-8")
        sites[host].append(f'<li><a href="{name}">{escape(title)}</a></li>')

    index = ["<h1>Gopher reading room</h1>",
             f"<p>{len(documents)} archived pages from {len(sites)} hosts.</p>"]
    for host, links in sites.items():
        index.append(f"<h2>{escape(host)}</h2>\n<ul>\n" + "\n".join(links) + "\n</ul>")
    (output / "index.html").write_text(page("Gopher reading room", "\n".join(index)),
                                       encoding="utf-8")
    return len(documents)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("corpus", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    print(f"Exported {export(args.corpus, args.output)} HTML documents.")
