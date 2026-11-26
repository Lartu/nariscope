import Foundation

public enum Renderer {
    private static let column = regex(#"(?<=\S) {3,}(?=\S)"#)
    private static let marks = regex(#"[|_\\/@#~=<>^*+]"#)
    private static let denseMarks = regex(#"[|_\\/@#~=<>^*+]{4,}"#)
    private static let letters = regex(#"[A-Za-z]{3,}"#)
    private static let network = regex(#"^[\w.*:/-]+$"#)
    private static let timestamp = regex(#"^\s*(?:(?:[A-Z][a-z]{2} )?[A-Z][a-z]{2} +\d{1,2} \d{2}:\d{2}:\d{2}|\d{1,4}[-/]\d{1,2}[-/]\d{1,4}[ T]+\d{2}:\d{2}|\d{2}:\d{2}:\d{2})\b"#)
    private static let ruler = regex(#"^(?:[-_=+| ]{8,}|\|[\d ]{6,})$"#)
    private static let underline = regex(#"^\s*(?:={3,}|-{3,})\s*$"#)
    private static let rule = regex(#"^[-_=*~]{4,}$"#)
    private static let wholeSource = regex(#"^\s*(?:<\?xml\b|%rec:\s)"#, [.caseInsensitive])
    private static let sourceBlock = regex(
        #"^[ \t]*<(html|svg|rss)\b[^>]*>[^\n]*\n.*?^[ \t]*</\1>[ \t]*$|^[ \t]*(\x60{3,}|~{3,})[^\n]*\n.*?^[ \t]*\2[ \t]*$"#,
        [.caseInsensitive, .anchorsMatchLines, .dotMatchesLineSeparators]
    )
    private static let metadata = regex(#"^(?:last )?updated (?:every\b|on\b|\d)"#, [.caseInsensitive])
    private static let terminal = regex(#"[.!?]["'”’)]?\s*$"#)
    private static let words = regex(#"[\p{L}]+(?:['’][\p{L}]+)*"#)
    private static let quote = regex(#"^(\s*(?:>\s*)+)(.*)$"#)
    private static let list = regex(#"^(\s*(?:[-*+] |\d+[.)] |[A-Za-z][.)] ))(.*)$"#)
    private static let url = regex(#"(?:https?|gopher)://[^\s<>"']+"#, [.caseInsensitive])

    private static func regex(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        // All patterns are static and covered by tests.
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> [NSTextCheckingResult] {
        regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    private static func has(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func trim(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    private static func expandTabs(_ text: String) -> String {
        var result = ""
        var column = 0
        for character in text {
            let width = character == "\t" ? 8 - column % 8 : 1
            result += character == "\t" ? String(repeating: " ", count: width) : String(character)
            column += width
        }
        return result
    }

    public static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#x27;")
    }

    public static func pre(_ text: String) -> String { "<pre tabindex=\"0\">\n\(escape(text))</pre>" }

    public static func styleElementText(_ css: String) -> String {
        // Keep closing tags inside the style element. Leave ordinary CSS
        // syntax intact, including '<' in media query comparisons.
        css.replacingOccurrences(of: "</style", with: "\\3C /style", options: .caseInsensitive)
    }

    public static func linkedText(_ text: String) -> String {
        var result = ""
        var start = text.startIndex
        for match in matches(url, text) {
            guard let range = Range(match.range, in: text) else { continue }
            var end = range.upperBound
            while end > range.lowerBound, ".,;:!?)]".contains(text[text.index(before: end)]) {
                end = text.index(before: end)
            }
            let value = String(text[range.lowerBound..<end])
            guard let candidate = URL(string: value), candidate.host != nil else { continue }
            result += escape(String(text[start..<range.lowerBound]))
            result += "<a href=\"\(escape(candidate.absoluteString))\">\(escape(value))</a>"
            start = end
        }
        return result + escape(String(text[start...]))
    }

    private struct Row {
        let line: String
        let bare: String
        let gaps: Set<Int>
        let wideGap: Bool
        let timestamp: Bool
        let art: Bool
        let edge: Bool

        init(_ line: String) {
            self.line = line
            let expanded = expandTabs(line)
            bare = trim(expanded)
            let columns = matches(column, expanded)
            gaps = Set(columns.map { NSMaxRange($0.range) })
            wideGap = columns.contains { $0.range.length >= 6 }
            timestamp = has(Renderer.timestamp, line)
            let visible = line.filter { !$0.isWhitespace }
            let symbols = visible.filter { !$0.isLetter && !$0.isNumber }.count
            let symbolHeavy = Double(symbols) >= Double(visible.count) * 0.55
            let isNetwork = has(network, bare) && visible.contains(where: \.isNumber)
            art = !visible.isEmpty && !isNetwork &&
                (matches(marks, visible).count >= 2 && symbolHeavy || has(denseMarks, line))
            edge = !visible.isEmpty && !isNetwork && symbols >= 2 && symbolHeavy && !has(letters, visible)
        }
    }

    private static func fixedRows(_ rows: [Row]) -> Set<Int> {
        var fixed: Set<Int> = []
        var pictures: Set<Int> = []
        for i in rows.indices {
            let row = rows[i]
            let neighbours = (max(0, i - 2)..<min(rows.count, i + 3)).filter { j in
                j != i && rows[min(i, j)...max(i, j)].allSatisfy { !$0.bare.isEmpty }
            }
            let aligned = neighbours.filter { !row.gaps.isDisjoint(with: rows[$0].gaps) }.count
            let drawing = row.art && neighbours.contains { rows[$0].art }
            if drawing { pictures.insert(i) }
            if drawing || aligned >= 2 || aligned >= 1 && row.wideGap
                || row.timestamp && neighbours.contains(where: { rows[$0].timestamp }) {
                fixed.insert(i)
            }
        }

        for start in pictures {
            for step in [-1, 1] {
                var i = start + step
                while rows.indices.contains(i), rows[i].edge, !pictures.contains(i) {
                    fixed.insert(i)
                    i += step
                }
            }
        }
        for i in rows.indices.dropFirst().dropLast()
            where fixed.contains(i - 1) && fixed.contains(i + 1) && !rows[i].bare.isEmpty {
            fixed.insert(i)
        }
        for i in fixed.sorted() where i > 0 {
            for j in stride(from: i - 1, through: max(0, i - 4), by: -1) {
                let row = rows[j]
                if row.bare.isEmpty {
                    if j == i - 1 { continue }
                    break
                }
                let isRuler = has(ruler, row.bare)
                let isHeader = row.gaps.contains { a in rows[i].gaps.contains { abs(a - $0) <= 2 } }
                guard isRuler || isHeader else { break }
                fixed.formUnion(j..<i)
                if isRuler, j > 0, !rows[j - 1].gaps.isEmpty, !rows[j - 1].bare.hasSuffix(".") {
                    fixed.insert(j - 1)
                }
            }
        }
        return fixed
    }

    private enum Kind { case plain, quote, list }

    private struct Line {
        let kind: Kind
        let prefix: String
        let body: String
        let source: String
        let width: Int
        let wordCount: Int

        init(_ line: String) {
            source = trim(line)
            let trailing = line.reversed().drop(while: \.isWhitespace).reversed()
            width = expandTabs(String(trailing)).count
            let matched = matches(quote, line).first.map { (Kind.quote, $0) }
                ?? matches(list, line).first.map { (Kind.list, $0) }
            if let (type, match) = matched,
               let prefixRange = Range(match.range(at: 1), in: line),
               let bodyRange = Range(match.range(at: 2), in: line) {
                kind = type
                prefix = String(line[prefixRange])
                body = trim(String(line[bodyRange]))
            } else {
                kind = .plain
                prefix = String(line.prefix(while: \.isWhitespace))
                body = source
            }
            wordCount = matches(words, body).count
        }
    }

    private static func shouldJoin(_ current: Line, _ next: Line, width: Double, anchors: Int) -> Bool {
        guard current.wordCount >= 5, next.wordCount > 0, current.width >= 30,
              next.kind != .list, (current.kind == .quote) == (next.kind == .quote),
              !has(metadata, next.body),
              !isUppercase(current.body), !isUppercase(next.body) else { return false }
        if current.kind == .quote,
           current.prefix.filter({ $0 == ">" }).count != next.prefix.filter({ $0 == ">" }).count { return false }
        let following = next.body.drop(while: { " \"'“‘([«".contains($0) })
        let continuation = following.first?.isLowercase == true
        let sentenceEnd = has(terminal, current.body)
        let nearMargin = Double(current.width) >= width - 9 && width >= 36
        let currentIndent = expandTabs(current.prefix).count
        let nextIndent = expandTabs(next.prefix).count
        let sameMargin = current.kind == .list ? nextIndent >= currentIndent : abs(currentIndent - nextIndent) <= 2
        if continuation, !sentenceEnd, nearMargin || sameMargin && current.width >= 40 { return true }
        guard nearMargin, anchors >= 2, sameMargin else { return false }
        let firstWord = next.body.prefix { !$0.isWhitespace }.count
        return !sentenceEnd || Double(current.width + 1 + firstWord) > width
    }

    private static func isUppercase(_ text: String) -> Bool {
        text == text.uppercased() && text != text.lowercased()
    }

    private static func prose(_ rows: ArraySlice<Row>, links: Bool) -> String {
        let lines = rows.map { Line($0.line) }
        let anchors = lines.filter { $0.wordCount >= 6 }.map(\.width).sorted()
        let upper = Array(anchors.dropFirst(anchors.count / 2))
        let width = upper.isEmpty ? 0 : Double(upper[upper.count / 2] + upper[(upper.count - 1) / 2]) / 2
        var groups: [(Kind, String)] = []
        var parts: [String] = []
        var kind = Kind.plain
        for i in lines.indices {
            let line = lines[i]
            if parts.isEmpty {
                kind = line.kind
                parts.append(kind == .quote ? line.body : line.source)
            } else { parts.append(line.body) }
            if i + 1 < lines.count, shouldJoin(line, lines[i + 1], width: width, anchors: anchors.count) { continue }
            let normalized = parts.joined(separator: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
            groups.append((kind, links ? linkedText(normalized) : escape(normalized)))
            parts.removeAll(keepingCapacity: true)
        }

        var result: [String] = []
        var i = 0
        while i < groups.count {
            let kind = groups[i].0
            var end = i + 1
            while end < groups.count && groups[end].0 == kind { end += 1 }
            let values = groups[i..<end].map(\.1)
            if kind == .list && values.allSatisfy({ ["- ", "* ", "+ "].contains(String($0.prefix(2))) }) {
                result.append("<ul>" + values.map { "<li>\($0.dropFirst(2))</li>" }.joined() + "</ul>")
            } else {
                let paragraph = "<p>" + values.joined(separator: "<br>\n") + "</p>"
                result.append(kind == .quote ? "<blockquote>\(paragraph)</blockquote>" : paragraph)
            }
            i = end
        }
        return result.joined(separator: "\n")
    }

    public static func document(_ input: String, original: Bool = false, links: Bool = false) -> String {
        let text = input.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if original || has(wholeSource, text) { return pre(text) }
        let rows = text.components(separatedBy: "\n").map(Row.init)
        var fixed = fixedRows(rows)
        var offset = text.startIndex
        var line = 0
        for block in matches(sourceBlock, text) {
            guard let range = Range(block.range, in: text) else { continue }
            line += text[offset..<range.lowerBound].filter { $0 == "\n" }.count
            let count = text[range].filter { $0 == "\n" }.count
            fixed.formUnion(line...(line + count))
            line += count
            offset = range.upperBound
        }
        let headings = Set(rows.indices.dropLast().filter { i in
            !rows[i].bare.isEmpty && rows[i].bare.count <= 85 && !fixed.contains(i)
                && !fixed.contains(i + 1) && has(underline, rows[i + 1].line)
        })
        var sections: [String] = []
        var i = 0
        while i < rows.count {
            let row = rows[i]
            if headings.contains(i) {
                sections.append("<h2>\(escape(row.bare))</h2>")
                i += 2
            } else if fixed.contains(i) {
                var end = i + 1
                while fixed.contains(end) { end += 1 }
                sections.append(pre(rows[i..<end].map(\.line).joined(separator: "\n")))
                i = end
            } else if row.bare.isEmpty {
                i += 1
            } else if has(rule, row.bare) {
                sections.append("<hr>")
                i += 1
            } else {
                var end = i + 1
                while end < rows.count, !rows[end].bare.isEmpty, !fixed.contains(end),
                      !headings.contains(end), !has(rule, rows[end].bare) { end += 1 }
                sections.append(prose(rows[i..<end], links: links))
                i = end
            }
        }
        return sections.joined(separator: "\n")
    }
}
