import AppKit
import XCTest

/// The notes renderer (design 1d; SPEC §5). Its shipped defect was structural:
/// every soft-wrapped source line became its own paragraph, so a fused note
/// arrived as a column of one-line stubs instead of prose.
///
/// Assertions are on the rendered STRING and on the attributes that carry
/// meaning (section labels, checkbox attachments, bold runs) — never on
/// point sizes or colors, which are design tokens and not behaviour.
final class MarkdownMiniRendererTests: XCTestCase {

    /// Stand-in for the static action-item glyph the caller injects.
    private let checkbox = NSImage(size: NSSize(width: 13, height: 13))

    private func render(_ markdown: String, checkbox: NSImage? = nil) -> NSAttributedString {
        MarkdownMiniRenderer.render(markdown, checkbox: checkbox)
    }

    // MARK: Paragraph assembly — the shipped defect

    /// Markdown's paragraph rule: consecutive non-blank lines are ONE
    /// paragraph, joined by a space. Pre-fix this rendered as
    /// "We shipped.\nIt went fine.\n" — two paragraphs, ragged column.
    func testSoftWrappedLinesJoinIntoOneParagraph() {
        XCTAssertEqual(
            render("We shipped the thing.\nIt went fine.\nNobody paged.").string,
            "We shipped the thing. It went fine. Nobody paged.\n"
        )
    }

    /// The counterpart: a BLANK line really does start a new paragraph, so the
    /// join above cannot be implemented by stripping all newlines.
    func testBlankLineStartsANewParagraph() {
        XCTAssertEqual(
            render("First paragraph.\n\nSecond paragraph.").string,
            "First paragraph.\nSecond paragraph.\n"
        )
    }

    /// Runs of blank lines collapse — a model that emits double spacing must
    /// not open empty paragraphs.
    func testRepeatedBlankLinesDoNotEmitEmptyParagraphs() {
        XCTAssertEqual(render("One.\n\n\n\nTwo.").string, "One.\nTwo.\n")
    }

    /// A bullet's lazy continuation belongs to the BULLET, not to a new
    /// paragraph after it.
    func testBulletContinuationLineJoinsTheBullet() {
        XCTAssertEqual(
            render("- Ship the migration\n  before Friday").string,
            "\u{2022}  Ship the migration before Friday\n"
        )
    }

    /// A heading always breaks the block it follows, blank line or not.
    func testHeadingBreaksThePrecedingParagraph() {
        XCTAssertEqual(render("trailing prose\n## Next").string, "trailing prose\nNEXT\n")
    }

    // MARK: Headings

    func testLevelTwoHeadingBecomesAnUppercaseSectionLabel() {
        let rendered = render("## Action items")
        XCTAssertEqual(rendered.string, "ACTION ITEMS\n")
        XCTAssertNotNil(
            rendered.attribute(MarkdownMiniRenderer.sectionLabelAttribute, at: 0, effectiveRange: nil),
            "History splices its validator cards on this attribute"
        )
    }

    /// Only `##` is a section label — `#` and `###` keep their case and must
    /// not be treated as splice points.
    func testOtherHeadingLevelsAreNotSectionLabels() {
        for source in ["# Weekly sync", "### Detail"] {
            let rendered = render(source)
            XCTAssertFalse(rendered.string.hasSuffix("\n\n"), source)
            XCTAssertEqual(rendered.string, String(source.drop(while: { $0 == "#" }).dropFirst()) + "\n")
            XCTAssertNil(
                rendered.attribute(MarkdownMiniRenderer.sectionLabelAttribute, at: 0, effectiveRange: nil),
                "\(source) must not read as a section label"
            )
        }
    }

    /// `#` with no space, or with nothing after it, is not a heading — a
    /// literal "#3 on the list" must survive as text.
    func testHashWithoutASpaceIsNotAHeading() {
        XCTAssertEqual(render("#3 on the list").string, "#3 on the list\n")
        XCTAssertEqual(render("####  too deep").string, "####  too deep\n")
    }

    // MARK: The dropped `Title:` line

    /// The fused output opens with `Title:` (SPEC §4.5) and the pane header
    /// already shows it, so it is dropped — case-insensitively.
    func testLeadingTitleLineIsDropped() {
        XCTAssertEqual(render("Title: Weekly sync\n\nBody text.").string, "Body text.\n")
        XCTAssertEqual(render("title: weekly sync\n\nBody text.").string, "Body text.\n")
    }

    /// Only the LEADING one. A "Title:" further down is the model talking
    /// about titles, and swallowing it would lose content.
    func testTitleLineIsKeptWhenItIsNotTheFirstBlock() {
        XCTAssertEqual(
            render("Opening line.\n\nTitle: something we discussed").string,
            "Opening line.\nTitle: something we discussed\n"
        )
    }

    // MARK: Action-item checkboxes

    /// Bullets get the static checkbox glyph ONLY under an Action-items
    /// heading (design 1d) — everywhere else they are plain bullets, so the
    /// notes pane never reads as a todo widget.
    func testCheckboxesAppearOnlyUnderTheActionItemsHeading() {
        let rendered = render(
            """
            ## Summary
            - not an action item

            ## Action items
            - Ship the migration
            """,
            checkbox: checkbox
        )
        let attachment = "\u{FFFC}"
        XCTAssertEqual(
            rendered.string,
            "SUMMARY\n\u{2022}  not an action item\nACTION ITEMS\n\(attachment)  Ship the migration\n"
        )
    }

    /// A later `##` heading ends the action-items section.
    func testCheckboxesStopAtTheNextSection() {
        let rendered = render("## Action items\n- one\n\n## Risks\n- two", checkbox: checkbox)
        XCTAssertEqual(
            rendered.string,
            "ACTION ITEMS\n\u{FFFC}  one\nRISKS\n\u{2022}  two\n"
        )
    }

    /// With no glyph supplied the renderer falls back to a plain bullet
    /// rather than emitting an empty attachment.
    func testNilCheckboxFallsBackToAPlainBullet() {
        XCTAssertEqual(render("## Action items\n- one").string, "ACTION ITEMS\n\u{2022}  one\n")
    }

    /// All three bullet markers are accepted, and each renders as the SAME
    /// normalized glyph — the model is not consistent about which it emits.
    func testAllBulletMarkersNormalize() {
        for marker in ["-", "*", "\u{2022}"] {
            XCTAssertEqual(render("\(marker) item").string, "\u{2022}  item\n", marker)
        }
    }

    /// A bare marker with no text is not a bullet — it is literal text, and
    /// dropping it would silently eat a line.
    func testEmptyBulletIsNotABullet() {
        XCTAssertEqual(render("- ").string, "-\n")
    }

    // MARK: Inline spans

    func testBoldItalicAndCodeMarkersAreConsumedAndStyled() {
        let rendered = render("a **bold** and *slanted* and `coded` run")
        XCTAssertEqual(rendered.string, "a bold and slanted and coded run\n")

        let bold = try? XCTUnwrap(
            rendered.attribute(.font, at: rendered.string.distance(
                from: rendered.string.startIndex,
                to: rendered.string.range(of: "bold")!.lowerBound
            ), effectiveRange: nil) as? NSFont
        )
        XCTAssertEqual(
            bold?.fontDescriptor.symbolicTraits.contains(.bold), true,
            "**bold** did not produce a bold run"
        )
        let italicIndex = rendered.string.distance(
            from: rendered.string.startIndex,
            to: rendered.string.range(of: "slanted")!.lowerBound
        )
        XCTAssertNotNil(rendered.attribute(.obliqueness, at: italicIndex, effectiveRange: nil))
    }

    /// Unmatched markers stay literal — the renderer must never eat a
    /// character because a closing marker never arrived.
    func testUnmatchedMarkersRenderLiterally() {
        XCTAssertEqual(render("5 * 3 = 15").string, "5 * 3 = 15\n")
        XCTAssertEqual(render("an **unclosed bold").string, "an **unclosed bold\n")
        XCTAssertEqual(render("a `unclosed code").string, "a `unclosed code\n")
        XCTAssertEqual(render("empty ** markers").string, "empty ** markers\n")
    }

    /// `**` must win over `*` — otherwise "**bold**" renders as an italic
    /// empty span followed by literal text.
    func testDoubleAsteriskIsNotParsedAsTwoItalics() {
        XCTAssertEqual(render("**x**").string, "x\n")
    }

    // MARK: Splice point for validator cards

    func testEndOfFirstSectionIsTheStartOfTheSecondLabel() {
        let rendered = render("## Summary\nbody text\n## Action items\n- one")
        let index = MarkdownMiniRenderer.endOfFirstSection(in: rendered)
        XCTAssertEqual(
            rendered.attributedSubstring(from: NSRange(location: index, length: "ACTION ITEMS".count)).string,
            "ACTION ITEMS"
        )
    }

    /// With only one section there is nowhere to splice before, so the card
    /// goes at the end rather than into the middle of the summary.
    func testEndOfFirstSectionIsTheEndWhenThereIsNoSecondSection() {
        let rendered = render("## Summary\nbody text")
        XCTAssertEqual(MarkdownMiniRenderer.endOfFirstSection(in: rendered), rendered.length)
    }

    // MARK: Degenerate input

    func testEmptyInputRendersNothing() {
        XCTAssertEqual(render("").string, "")
        XCTAssertEqual(render("\n\n\n").string, "")
    }
}
