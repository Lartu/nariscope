#!/usr/bin/env python3
"""Conservative, auditable reflow for Gopher text documents.

The module has no third-party dependencies.  It can fetch/crawl Gopher menus,
render type-0 text, and explain every joined or preserved line boundary.
"""

from __future__ import annotations

import argparse
import json
import math
import re
import socket
import statistics
import time
from collections import Counter, deque
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Iterable, Iterator, Sequence


MENU_TYPES = set("0123456789+TgIihs;dMcp")
LIST_RE = re.compile(r"^(\s*)([-*+] |\d+[.)] |[A-Za-z][.)] )(.*)$")
QUOTE_RE = re.compile(r"^(\s*(?:>\s*)+)(.*)$")
WORD_RE = re.compile(r"[\w'’-]+", re.UNICODE)
DECORATIVE_RE = re.compile(r"^\s*(?:[-=_~*+#|.:/\\]{4,}\s*)+$")
BORDER_RE = re.compile(r"^\s*[+|].*[+|]\s*$")


@dataclass(frozen=True)
class GopherItem:
    item_type: str
    display: str
    selector: str
    host: str
    port: int

    @property
    def url(self) -> str:
        return f"gopher://{self.host}:{self.port}/{self.item_type}{self.selector}"


@dataclass
class BoundaryDecision:
    line: int
    join: bool
    score: float
    reason: str
    width: int | None


@dataclass
class ReflowResult:
    text: str
    decisions: list[BoundaryDecision]
    inferred_widths: list[int]


@dataclass
class CrawlRecord:
    url: str
    item_type: str
    ok: bool
    bytes: int = 0
    error: str | None = None
    raw_file: str | None = None
    rendered_file: str | None = None
    joined: int = 0
    preserved: int = 0


def fetch_gopher(host: str, port: int = 70, selector: str = "", *,
                 timeout: float = 8.0, max_bytes: int = 2_000_000) -> bytes:
    """Fetch one selector using RFC 1436's selector + CRLF request."""
    if any(c in selector for c in "\r\n"):
        raise ValueError("selector may not contain CR or LF")
    chunks: list[bytes] = []
    total = 0
    with socket.create_connection((host, port), timeout=timeout) as sock:
        sock.settimeout(timeout)
        sock.sendall(selector.encode("utf-8", "surrogateescape") + b"\r\n")
        while True:
            chunk = sock.recv(min(65536, max_bytes + 1 - total))
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
            if total > max_bytes:
                raise ValueError(f"response exceeds {max_bytes} bytes")
    data = b"".join(chunks)
    # A lone dot terminates text/menu responses; dot-stuffing is permitted.
    data = re.sub(br"\r?\n\.\r?\n?$", b"\n", data)
    data = re.sub(br"(?m)^\.\.", b".", data)
    return data


def decode_text(data: bytes) -> str:
    """Decode old and modern Gopher text without throwing data away."""
    for encoding in ("utf-8", "cp1252", "latin-1"):
        try:
            return data.decode(encoding)
        except UnicodeDecodeError:
            pass
    return data.decode("utf-8", "replace")


def parse_menu(data: bytes, default_host: str = "", default_port: int = 70) -> list[GopherItem]:
    items: list[GopherItem] = []
    for raw in decode_text(data).splitlines():
        if raw == "." or not raw:
            continue
        fields = raw[1:].split("\t")
        if len(raw) < 1 or len(fields) < 2:
            continue
        item_type = raw[0]
        if item_type not in MENU_TYPES:
            continue
        display, selector = fields[0], fields[1]
        host = fields[2] if len(fields) > 2 and fields[2] else default_host
        try:
            port = int(fields[3]) if len(fields) > 3 else default_port
        except ValueError:
            port = default_port
        items.append(GopherItem(item_type, display, selector, host, port))
    return items


def _prefix_and_body(line: str) -> tuple[str, str, str]:
    """Return (kind, repeatable prefix, body)."""
    quote = QUOTE_RE.match(line)
    if quote:
        return "quote", quote.group(1), quote.group(2)
    listed = LIST_RE.match(line)
    if listed:
        return "list", listed.group(1) + listed.group(2), listed.group(3)
    return "plain", line[: len(line) - len(line.lstrip())], line.lstrip()


def _layout_score(lines: Sequence[str], i: int) -> tuple[float, list[str]]:
    line = lines[i]
    reasons: list[str] = []
    score = 0.0
    if "\t" in line:
        score += 4; reasons.append("tab")
    if DECORATIVE_RE.match(line) or BORDER_RE.match(line):
        score += 5; reasons.append("border/decorative run")
    if re.search(r"\S {2,}\S", line):
        score += 2; reasons.append("internal columns")
        nearby_columns = sum(
            bool(re.search(r"\S {2,}\S", lines[j]))
            for j in range(max(0, i - 2), min(len(lines), i + 3)) if j != i
        )
        if nearby_columns:
            score += 2; reasons.append("repeated column spacing")
    nonspace = [c for c in line if not c.isspace()]
    if nonspace:
        alnum_ratio = sum(c.isalnum() for c in nonspace) / len(nonspace)
        if alnum_ratio < .45:
            score += 2; reasons.append("symbol-heavy")
    # Alignment is far stronger than punctuation counts.
    gaps = {m.start() for m in re.finditer(r" {2,}", line)}
    for j in range(max(0, i - 2), min(len(lines), i + 3)):
        if j == i:
            continue
        other = {m.start() for m in re.finditer(r" {2,}", lines[j])}
        if gaps & other:
            score += 1.5; reasons.append("aligned gaps")
            break
    return score, reasons


def _prose_like(line: str) -> bool:
    _, _, body = _prefix_and_body(line)
    words = WORD_RE.findall(body)
    if len(words) < 2:
        return False
    chars = [c for c in body if not c.isspace()]
    return bool(chars) and sum(c.isalnum() for c in chars) / len(chars) >= .62


def _candidate_width(lines: Sequence[str], start: int, stop: int) -> int | None:
    lengths = [len(lines[i].rstrip()) for i in range(start, stop)
               if _prose_like(lines[i])]
    # One break is not a pattern.  Requiring at least two consecutive
    # boundaries prevents headings/subheadings such as "status\nupdated ..."
    # from inventing a local wrap width.
    if len(lengths) < 3:
        return None
    # A wrapper's width lies near the longest non-final lines.  The median of
    # the upper third is robust to headings and one unusually long URL.
    upper = sorted(lengths)[max(0, math.floor(len(lengths) * 2 / 3)):]
    width = round(statistics.median(upper))
    # Below this, ordinary verse, labels, and navigation lists dominate.  A
    # local narrow column can still be supported later, but width alone should
    # not cause it to be flattened.
    return width if width >= 35 else None


def _regions(lines: Sequence[str]) -> Iterator[tuple[int, int]]:
    start = 0
    for i, line in enumerate(lines + [""]):
        if not line.strip():
            if start < i:
                yield start, i
            start = i + 1


def reflow_text(text: str, *, threshold: float = 3.0) -> ReflowResult:
    """Conservatively join likely soft wraps while retaining an audit trail."""
    newline = "\r\n" if text.count("\r\n") > text.count("\n") / 2 else "\n"
    lines = text.replace("\r\n", "\n").replace("\r", "\n").split("\n")
    decisions: list[BoundaryDecision] = []
    widths: list[int] = []
    joins: set[int] = set()

    for start, stop in _regions(lines):
        width = _candidate_width(lines, start, stop)
        if width is not None:
            widths.append(width)
        for i in range(start, stop - 1):
            current, following = lines[i], lines[i + 1]
            kind1, prefix1, body1 = _prefix_and_body(current)
            kind2, prefix2, body2 = _prefix_and_body(following)
            layout1, why1 = _layout_score(lines, i)
            layout2, why2 = _layout_score(lines, i + 1)
            score = 0.0
            reasons: list[str] = []

            if not (_prose_like(current) and _prose_like(following)):
                score -= 4; reasons.append("non-prose/short line")
            else:
                score += 1; reasons.append("prose-like neighbours")
            if layout1 >= 3 or layout2 >= 3:
                score -= 6; reasons.append("layout: " + ", ".join(dict.fromkeys(why1 + why2)))

            compatible = False
            if kind1 == kind2 == "plain" and prefix1 == prefix2:
                compatible = True
            elif kind1 == kind2 == "quote" and prefix1 == prefix2:
                compatible = True
            elif kind1 == "list" and kind2 == "plain" and len(prefix2) >= len(prefix1):
                compatible = True
            elif kind1 == "plain" and kind2 == "plain" and abs(len(prefix1) - len(prefix2)) <= 1:
                compatible = True
            if compatible:
                score += 1; reasons.append("compatible prefix/indent")
            else:
                score -= 5; reasons.append("structural prefix change")

            if width is not None:
                first = WORD_RE.search(body2)
                first_len = len(first.group(0)) if first else 0
                line_len = len(current.rstrip())
                if line_len >= width - 10 and line_len + 1 + first_len > width:
                    score += 3; reasons.append(f"next word would exceed width {width}")
                elif line_len >= width - 10:
                    score += 1; reasons.append(f"line ends near width {width}")
                elif line_len < width - 16:
                    score -= 2; reasons.append(f"short before inferred width {width}")
            if re.search(r"[.!?][\]\)'\"]?\s*$", body1):
                score -= 1.5; reasons.append("sentence-ending punctuation")
            if body2[:1].islower():
                score += .5; reasons.append("lowercase continuation")

            join = score >= threshold
            if join:
                joins.add(i)
            decisions.append(BoundaryDecision(i + 1, join, score, "; ".join(reasons), width))

    out: list[str] = []
    for i, line in enumerate(lines):
        if i and i - 1 in joins:
            kind, prefix, body = _prefix_and_body(line)
            # Repeated quote prefixes are display syntax; continuation indent
            # and list markers are likewise omitted on a soft join.
            out.append(" " + body.strip())
        else:
            if i:
                out.append(newline)
            out.append(line.rstrip())
    return ReflowResult("".join(out), decisions, widths)


DEFAULT_SEEDS = [
    "gopher.floodgap.com:70/",
    "sdf.org:70/",
    "tildeverse.org:70/",
    "i-logout.cz:70/",
    "gopher.club:70/",
    "gopher.black:70/",
]


def parse_seed(value: str) -> tuple[str, int, str]:
    value = value.removeprefix("gopher://")
    authority, _, selector = value.partition("/")
    host, sep, port_s = authority.partition(":")
    return host, int(port_s) if sep else 70, "/" + selector if selector else ""


def safe_name(n: int, item: GopherItem) -> str:
    label = re.sub(r"[^A-Za-z0-9._-]+", "_", item.display).strip("_")[:55]
    return f"{n:04d}_{item.host}_{label or 'document'}"


def crawl(seeds: Sequence[str], output: Path, *, max_documents: int = 40,
          max_menus: int = 80, timeout: float = 7.0, delay: float = .08,
          same_seed_hosts: bool = True) -> list[CrawlRecord]:
    output.mkdir(parents=True, exist_ok=True)
    allowed = {parse_seed(s)[0].lower() for s in seeds}
    queue = deque(GopherItem("1", host, selector, host, port)
                  for host, port, selector in map(parse_seed, seeds))
    seen: set[tuple[str, int, str, str]] = set()
    records: list[CrawlRecord] = []
    documents = menus = 0

    while queue and documents < max_documents and menus < max_menus:
        item = queue.popleft()
        key = (item.host.lower(), item.port, item.item_type, item.selector)
        if key in seen or (same_seed_hosts and item.host.lower() not in allowed):
            continue
        seen.add(key)
        if item.item_type not in {"0", "1"}:
            continue
        try:
            data = fetch_gopher(item.host, item.port, item.selector, timeout=timeout)
            if item.item_type == "1":
                menus += 1
                children = parse_menu(data, item.host, item.port)
                # Menus stay structured: enqueue entries, never reflow their rows.
                for child in children:
                    if child.item_type in {"0", "1"}:
                        queue.append(child)
                records.append(CrawlRecord(item.url, "1", True, len(data)))
            else:
                documents += 1
                base = safe_name(documents, item)
                raw_path = output / f"{base}.txt"
                rendered_path = output / f"{base}.reflowed.txt"
                raw_path.write_bytes(data)
                result = reflow_text(decode_text(data))
                rendered_path.write_text(result.text, encoding="utf-8")
                records.append(CrawlRecord(
                    item.url, "0", True, len(data), raw_file=raw_path.name,
                    rendered_file=rendered_path.name,
                    joined=sum(d.join for d in result.decisions),
                    preserved=sum(not d.join for d in result.decisions),
                ))
        except Exception as exc:  # corpus work should record and continue
            records.append(CrawlRecord(item.url, item.item_type, False, error=f"{type(exc).__name__}: {exc}"))
        time.sleep(delay)

    (output / "manifest.json").write_text(
        json.dumps([asdict(r) for r in records], ensure_ascii=False, indent=2), encoding="utf-8")
    return records


def _cli() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    render = sub.add_parser("render", help="reflow one local text file")
    render.add_argument("input", type=Path)
    render.add_argument("-o", "--output", type=Path)
    render.add_argument("--explain", action="store_true")
    crawler = sub.add_parser("crawl", help="download and reflow a bounded corpus")
    crawler.add_argument("-o", "--output", type=Path, default=Path("corpus"))
    crawler.add_argument("--seed", action="append", default=[])
    crawler.add_argument("--max-documents", type=int, default=40)
    crawler.add_argument("--max-menus", type=int, default=80)
    crawler.add_argument("--timeout", type=float, default=7.0)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _cli().parse_args(argv)
    if args.command == "render":
        text = args.input.read_text(encoding="utf-8", errors="replace")
        result = reflow_text(text)
        if args.output:
            args.output.write_text(result.text, encoding="utf-8")
        else:
            print(result.text, end="")
        if args.explain:
            print(json.dumps([asdict(d) for d in result.decisions], indent=2))
    else:
        records = crawl(args.seed or DEFAULT_SEEDS, args.output,
                        max_documents=args.max_documents, max_menus=args.max_menus,
                        timeout=args.timeout)
        ok_docs = sum(r.ok and r.item_type == "0" for r in records)
        failures = sum(not r.ok for r in records)
        print(f"downloaded {ok_docs} text documents; {failures} failed requests; manifest: {args.output / 'manifest.json'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
