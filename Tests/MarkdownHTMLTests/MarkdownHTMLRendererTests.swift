// SPDX-License-Identifier: Apache-2.0
//
//  MarkdownHTMLRendererTests.swift
//  MarkdownHTMLTests
//
//  Verifies that the Markdown → HTML renderer emits the expected elements for
//  the constructs the project manual uses, and that text is HTML-escaped.
//

import XCTest
@testable import MarkdownHTML

final class MarkdownHTMLRendererTests: XCTestCase {

    /// Renders markdown to a full page and returns the HTML string.
    /// - Parameter markdown: (`String`) The Markdown source.
    /// - Returns: (`String`) The rendered HTML document.
    private func render(_ markdown: String) -> String {
        MarkdownHTMLRenderer.renderPage(markdown: markdown, title: "Test")
    }

    /// The output is a complete HTML document carrying the given title.
    func testProducesFullPageWithTitle() {
        let html = render("# Hi")
        XCTAssertTrue(html.contains("<!DOCTYPE html>"))
        XCTAssertTrue(html.contains("<title>Test</title>"))
    }

    /// ATX headings map to the matching heading level.
    func testHeadingLevels() {
        let html = render("# One\n\n## Two")
        XCTAssertTrue(html.contains("<h1>One</h1>"))
        XCTAssertTrue(html.contains("<h2>Two</h2>"))
    }

    /// Inline emphasis, strong, and code render to their HTML elements.
    func testInlineFormatting() {
        let html = render("A **bold** and *em* and `code` word.")
        XCTAssertTrue(html.contains("<strong>bold</strong>"))
        XCTAssertTrue(html.contains("<em>em</em>"))
        XCTAssertTrue(html.contains("<code>code</code>"))
    }

    /// Fenced code blocks render as <pre><code> and tag the language.
    func testFencedCodeBlock() {
        let html = render("```bash\nls -la\n```")
        XCTAssertTrue(html.contains("<pre><code class=\"language-bash\">"))
        XCTAssertTrue(html.contains("ls -la"))
    }

    /// Bullet lists render as <ul>/<li>.
    func testUnorderedList() {
        let html = render("- a\n- b")
        XCTAssertTrue(html.contains("<ul>"))
        XCTAssertTrue(html.contains("<li>a"))
        XCTAssertTrue(html.contains("<li>b"))
    }

    /// Links render to an anchor with the destination.
    func testLink() {
        let html = render("[site](https://grumptech.dev)")
        XCTAssertTrue(html.contains("<a href=\"https://grumptech.dev\">site</a>"))
    }

    /// GitHub-flavored tables render to <table> with header and body cells.
    func testTable() {
        let markdown = """
        | Field | Meaning |
        |-------|---------|
        | name  | the key |
        """
        let html = render(markdown)
        XCTAssertTrue(html.contains("<table>"))
        XCTAssertTrue(html.contains("<th>Field</th>"))
        XCTAssertTrue(html.contains("<td>the key</td>"))
    }

    /// Angle brackets and ampersands in text are HTML-escaped.
    func testEscaping() {
        let html = render("use <Shortcut Input> & go")
        XCTAssertTrue(html.contains("&lt;Shortcut Input&gt;"))
        XCTAssertTrue(html.contains("&amp;"))
        XCTAssertFalse(html.contains("<Shortcut Input>"))
    }
}
