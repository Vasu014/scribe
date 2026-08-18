import AppKit

/// Minimal display-only markdown → `NSAttributedString` renderer covering
/// exactly the History notes-pane subset (design 1d; SPEC §5 "rendered
/// markdown"): `#`/`##`/`###` headings, `**bold**` / `*italic*` / `` `code` ``
/// inline spans, and `-`/`*`/`•` bullets. A leading `Title:` line from the
/// fused output (SPEC §4.5 output format) is dropped — the notes pane header
/// already shows the session title.
///
/// Bullets under an `## Action items` heading render with a STATIC checkbox
/// glyph (design 1d: square + border, non-interactive — v0 stores no
/// action-item done-ness and this surface must not become a todo widget,
/// SPEC §5). The glyph is injected by the caller so the renderer stays a
/// pure text transform.
///
/// NOT a general markdown library — display-only by design ("do not invest",
/// SPEC §5: this window is deleted in Phase 3). Deliberate limitations:
/// no nested lists, links, images, tables, block quotes, task-list syntax,
/// or fenced code blocks; unmatched or unrecognized markers render as
/// literal text. `##` headings render as the design's uppercase 12 pt
/// section labels.
enum MarkdownMiniRenderer {

    // Type (design 1d; native system equivalents over the HTML hex values).
    private static let bodyFont = NSFont.systemFont(ofSize: 13)
    private static let bodyColor = NSColor.labelColor // design #333
    /// Design 13 pt / CSS line-height 1.55 ≈ 1.25 AppKit multiple (same
    /// conversion as the scratchpad body).
    private static let lineHeightMultiple: CGFloat = 1.25

    // MARK: - Entry

    /// Renders the notes-pane markdown subset. `checkbox` is the static
    /// action-item glyph (13×13); pass `nil` to fall back to a plain bullet.
    static func render(_ markdown: String, checkbox: NSImage?) -> NSAttributedString {
        let output = NSMutableAttributedString()
        /// Lowercased text of the current `##` section — bullets under
        /// "Action items" get checkbox glyphs (design 1d).
        var section = ""
        /// True once the fused output's leading `Title:` line was dropped.
        var droppedTitle = false

        for rawLine in markdown.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if !droppedTitle, output.length == 0, line.lowercased().hasPrefix("title:") {
                droppedTitle = true // the pane header shows the title (design 1d)
                continue
            }

            if let (level, text) = heading(line) {
                section = level == 2 ? text.lowercased() : ""
                appendHeading(text, level: level, to: output)
                continue
            }

            if let text = bulletText(line) {
                let checkboxBullet = checkbox != nil && section.contains("action item")
                appendBullet(text, checkbox: checkboxBullet ? checkbox : nil, to: output)
                continue
            }

            appendBody(line, to: output)
        }
        return output
    }

    // MARK: - Line classification

    /// `#`/`##`/`###` heading (level 1–3) or `nil`.
    private static func heading(_ line: String) -> (level: Int, text: String)? {
        var count = 0
        var rest = Substring(line)
        while rest.hasPrefix("#") {
            count += 1
            rest = rest.dropFirst()
        }
        guard (1...3).contains(count), rest.hasPrefix(" ") else { return nil }
        let text = rest.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : (count, text)
    }

    /// Bullet-line text for `- `/`* `/`• ` prefixes, else `nil`.
    private static func bulletText(_ line: String) -> String? {
        for marker in ["- ", "* ", "• "] where line.hasPrefix(marker) {
            let text = String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : text
        }
        return nil
    }

    // MARK: - Blocks

    private static func appendHeading(_ text: String, level: Int, to output: NSMutableAttributedString) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacingBefore = level == 2 ? 14 : 10
        paragraph.paragraphSpacing = 6
        var attributes: [NSAttributedString.Key: Any] = [.paragraphStyle: paragraph]
        switch level {
        case 1:
            attributes[.font] = NSFont.systemFont(ofSize: 15, weight: .semibold)
            attributes[.foregroundColor] = bodyColor
        case 2:
            // Design 1d section label: 12 pt semibold UPPERCASE, black 50%,
            // 0.05 em tracking ("SUMMARY", "ACTION ITEMS").
            attributes[.font] = NSFont.systemFont(ofSize: 12, weight: .semibold)
            attributes[.foregroundColor] = NSColor.secondaryLabelColor
            attributes[.kern] = 0.6
        default:
            attributes[.font] = NSFont.systemFont(ofSize: 13, weight: .semibold)
            attributes[.foregroundColor] = bodyColor
        }
        let label = level == 2 ? text.uppercased() : text
        output.append(NSAttributedString(string: label + "\n", attributes: attributes))
    }

    private static func appendBullet(_ text: String, checkbox: NSImage?, to output: NSMutableAttributedString) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacingBefore = 3
        paragraph.paragraphSpacing = 3
        paragraph.lineHeightMultiple = lineHeightMultiple
        paragraph.lineBreakMode = .byWordWrapping
        let base: [NSAttributedString.Key: Any] = [
            .font: bodyFont,
            .foregroundColor: bodyColor,
            .paragraphStyle: paragraph,
        ]

        if let checkbox {
            // Static checkbox glyph + hanging indent (design 1d: 13 pt box,
            // non-interactive — SPEC §5).
            paragraph.headIndent = 22
            let attachment = NSTextAttachment()
            attachment.image = checkbox
            attachment.bounds = CGRect(x: 0, y: bodyFont.descender - 2, width: 13, height: 13)
            output.append(NSAttributedString(attachment: attachment))
            output.append(NSAttributedString(string: "  ", attributes: base))
            appendInline(text, to: output, base: base)
        } else {
            paragraph.headIndent = 13
            output.append(NSAttributedString(string: "•  ", attributes: base))
            appendInline(text, to: output, base: base)
        }
        output.append(NSAttributedString(string: "\n", attributes: base))
    }

    private static func appendBody(_ text: String, to output: NSMutableAttributedString) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacingBefore = 2
        paragraph.paragraphSpacing = 6
        paragraph.lineHeightMultiple = lineHeightMultiple
        paragraph.lineBreakMode = .byWordWrapping
        let base: [NSAttributedString.Key: Any] = [
            .font: bodyFont,
            .foregroundColor: bodyColor,
            .paragraphStyle: paragraph,
        ]
        appendInline(text, to: output, base: base)
        output.append(NSAttributedString(string: "\n", attributes: base))
    }

    // MARK: - Inline spans

    /// Inline token kinds recognized by the scanner.
    private enum Span {
        case plain(String)
        case bold(String)
        case italic(String)
        case code(String)
    }

    /// Appends `text` with `**bold**`, `*italic*`, and `` `code` `` spans
    /// applied (no nesting inside bold/code — v0 display fidelity is enough).
    private static func appendInline(
        _ text: String, to output: NSMutableAttributedString, base: [NSAttributedString.Key: Any]
    ) {
        for span in spans(in: text) {
            switch span {
            case .plain(let string):
                output.append(NSAttributedString(string: string, attributes: base))
            case .bold(let string):
                var attributes = base
                attributes[.font] = NSFont.systemFont(ofSize: 13, weight: .semibold)
                output.append(NSAttributedString(string: string, attributes: attributes))
            case .italic(let string):
                var attributes = base
                attributes[.obliqueness] = 0.15 // SF Pro has no true italic cut
                output.append(NSAttributedString(string: string, attributes: attributes))
            case .code(let string):
                var attributes = base
                attributes[.font] = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
                attributes[.foregroundColor] = NSColor.secondaryLabelColor
                output.append(NSAttributedString(string: string, attributes: attributes))
            }
        }
    }

    /// Single-pass scanner: `**…**` → bold, `*…*` → italic, `` `…` `` →
    /// code; unmatched markers stay literal.
    private static func spans(in text: String) -> [Span] {
        var result: [Span] = []
        var plain = ""

        func flushPlain() {
            if !plain.isEmpty {
                result.append(.plain(plain))
                plain = ""
            }
        }

        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)

            if character == "*", next < text.endIndex, text[next] == "*" {
                // **bold**
                let start = text.index(after: next)
                if let close = text.range(of: "**", range: start..<text.endIndex) {
                    flushPlain()
                    result.append(.bold(String(text[start..<close.lowerBound])))
                    index = close.upperBound
                    continue
                }
            } else if character == "*" {
                // *italic* (no * inside)
                let start = next
                if let close = text.range(of: "*", range: start..<text.endIndex) {
                    let inner = text[start..<close.lowerBound]
                    if !inner.isEmpty {
                        flushPlain()
                        result.append(.italic(String(inner)))
                        index = close.upperBound
                        continue
                    }
                }
            } else if character == "`" {
                // `code`
                let start = next
                if let close = text.range(of: "`", range: start..<text.endIndex) {
                    let inner = text[start..<close.lowerBound]
                    if !inner.isEmpty {
                        flushPlain()
                        result.append(.code(String(inner)))
                        index = close.upperBound
                        continue
                    }
                }
            }

            plain.append(character)
            index = next
        }
        flushPlain()
        return result
    }
}
