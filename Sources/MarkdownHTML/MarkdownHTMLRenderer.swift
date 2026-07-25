// SPDX-License-Identifier: Apache-2.0
//
//  MarkdownHTMLRenderer.swift
//  MarkdownHTML
//
//  Renders a Markdown source string into a complete, self-contained HTML page
//  (embedded CSS, no external assets) suitable for double-clicking open in any
//  browser. Parsing is done by Apple's swift-markdown (cmark-gfm), and the
//  markup tree is walked with a `MarkupVisitor` that emits HTML.
//
//  This module is used only by the build-time `md2html` tool. It is deliberately
//  kept out of the shipped `RunShortcutsMCP` executable's dependency graph, so
//  the distributed binary never links swift-markdown.
//

import Markdown

/// A `MarkupVisitor` that converts a parsed Markdown document into an HTML
/// fragment, plus a convenience wrapper that produces a full standalone page.
///
/// Covers the constructs used by the project manual: headings, paragraphs,
/// emphasis/strong, inline and fenced code, ordered/unordered lists,
/// block quotes, thematic breaks, links, soft/hard breaks, and GitHub-flavored
/// tables. Any node type not explicitly handled falls back to rendering its
/// children (`defaultVisit`), so unknown inline wrappers degrade to their text.
public struct MarkdownHTMLRenderer: MarkupVisitor {
    /// (`String`) Each visit returns an HTML string.
    public typealias Result = String

    /// Creates a renderer. Stateless; a fresh instance is cheap.
    public init() {}

    /// Parses `markdown` and wraps the rendered body in a complete HTML page.
    /// - Parameters:
    ///   - markdown: (`String`) The Markdown source to convert.
    ///   - title: (`String`) The page `<title>` and top-of-document label.
    /// - Returns: (`String`) A full `<!DOCTYPE html>` document with embedded CSS.
    public static func renderPage(markdown: String, title: String) -> String {
        let document = Document(parsing: markdown)
        var renderer = MarkdownHTMLRenderer()
        let body = renderer.visit(document)
        return page(title: title, body: body)
    }

    // MARK: - MarkupVisitor

    /// Fallback visitor: renders a node by concatenating its children's HTML.
    /// - Parameter markup: (`Markup`) The node whose children should be rendered.
    /// - Returns: (`String`) The concatenated HTML of all child nodes.
    public mutating func defaultVisit(_ markup: Markup) -> String {
        renderChildren(of: markup)
    }

    /// Renders every child of a node in order and joins the results.
    /// - Parameter markup: (`Markup`) The parent node.
    /// - Returns: (`String`) Concatenated child HTML (empty if there are no children).
    private mutating func renderChildren(of markup: Markup) -> String {
        var out = ""
        for child in markup.children {
            out += visit(child)
        }
        return out
    }

    /// Renders a paragraph as a `<p>` block.
    /// - Parameter paragraph: (`Paragraph`) The paragraph node.
    /// - Returns: (`String`) `<p>…</p>` with the inline content rendered.
    public mutating func visitParagraph(_ paragraph: Paragraph) -> String {
        "<p>\(renderChildren(of: paragraph))</p>\n"
    }

    /// Renders an ATX/setext heading as `<h1>`…`<h6>` per its level.
    /// - Parameter heading: (`Heading`) The heading node (`level` is 1–6).
    /// - Returns: (`String`) The heading element with rendered inline content.
    public mutating func visitHeading(_ heading: Heading) -> String {
        let level = min(max(heading.level, 1), 6)
        return "<h\(level)>\(renderChildren(of: heading))</h\(level)>\n"
    }

    /// Renders literal text, HTML-escaped.
    /// - Parameter text: (`Text`) The text node.
    /// - Returns: (`String`) The escaped text.
    public mutating func visitText(_ text: Text) -> String {
        escape(text.string)
    }

    /// Renders a soft break (a wrapped source line) as a single space.
    /// - Parameter softBreak: (`SoftBreak`) The soft-break node.
    /// - Returns: (`String`) A single space.
    public mutating func visitSoftBreak(_ softBreak: SoftBreak) -> String {
        " "
    }

    /// Renders a hard line break as `<br>`.
    /// - Parameter lineBreak: (`LineBreak`) The hard-break node.
    /// - Returns: (`String`) `<br>` plus a newline.
    public mutating func visitLineBreak(_ lineBreak: LineBreak) -> String {
        "<br>\n"
    }

    /// Renders strong emphasis as `<strong>`.
    /// - Parameter strong: (`Strong`) The strong node.
    /// - Returns: (`String`) `<strong>…</strong>`.
    public mutating func visitStrong(_ strong: Strong) -> String {
        "<strong>\(renderChildren(of: strong))</strong>"
    }

    /// Renders emphasis as `<em>`.
    /// - Parameter emphasis: (`Emphasis`) The emphasis node.
    /// - Returns: (`String`) `<em>…</em>`.
    public mutating func visitEmphasis(_ emphasis: Emphasis) -> String {
        "<em>\(renderChildren(of: emphasis))</em>"
    }

    /// Renders inline code as `<code>`, escaped.
    /// - Parameter inlineCode: (`InlineCode`) The inline-code node.
    /// - Returns: (`String`) `<code>…</code>` with escaped contents.
    public mutating func visitInlineCode(_ inlineCode: InlineCode) -> String {
        "<code>\(escape(inlineCode.code))</code>"
    }

    /// Renders a fenced/indented code block as `<pre><code>`, escaped, tagging the
    /// language as a `language-…` class when present.
    /// - Parameter codeBlock: (`CodeBlock`) The code-block node.
    /// - Returns: (`String`) A `<pre><code>…</code></pre>` block.
    public mutating func visitCodeBlock(_ codeBlock: CodeBlock) -> String {
        let languageClass = codeBlock.language.map { " class=\"language-\(escape($0))\"" } ?? ""
        return "<pre><code\(languageClass)>\(escape(codeBlock.code))</code></pre>\n"
    }

    /// Renders a link as `<a href>`; a missing destination yields an empty href.
    /// - Parameter link: (`Link`) The link node.
    /// - Returns: (`String`) `<a href="…">…</a>`.
    public mutating func visitLink(_ link: Link) -> String {
        let href = escape(link.destination ?? "")
        return "<a href=\"\(href)\">\(renderChildren(of: link))</a>"
    }

    /// Renders a bullet list as `<ul>`.
    /// - Parameter unorderedList: (`UnorderedList`) The list node.
    /// - Returns: (`String`) `<ul>…</ul>` with its list items.
    public mutating func visitUnorderedList(_ unorderedList: UnorderedList) -> String {
        "<ul>\n\(renderChildren(of: unorderedList))</ul>\n"
    }

    /// Renders a numbered list as `<ol>`.
    /// - Parameter orderedList: (`OrderedList`) The list node.
    /// - Returns: (`String`) `<ol>…</ol>` with its list items.
    public mutating func visitOrderedList(_ orderedList: OrderedList) -> String {
        "<ol>\n\(renderChildren(of: orderedList))</ol>\n"
    }

    /// Renders a list item as `<li>`.
    /// - Parameter listItem: (`ListItem`) The list-item node.
    /// - Returns: (`String`) `<li>…</li>` with its contents.
    public mutating func visitListItem(_ listItem: ListItem) -> String {
        "<li>\(renderChildren(of: listItem))</li>\n"
    }

    /// Renders a block quote as `<blockquote>`.
    /// - Parameter blockQuote: (`BlockQuote`) The block-quote node.
    /// - Returns: (`String`) `<blockquote>…</blockquote>` with its contents.
    public mutating func visitBlockQuote(_ blockQuote: BlockQuote) -> String {
        "<blockquote>\n\(renderChildren(of: blockQuote))</blockquote>\n"
    }

    /// Renders a thematic break as `<hr>`.
    /// - Parameter thematicBreak: (`ThematicBreak`) The thematic-break node.
    /// - Returns: (`String`) `<hr>` plus a newline.
    public mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) -> String {
        "<hr>\n"
    }

    /// Renders a GitHub-flavored table as a `<table>` with `<thead>`/`<tbody>`.
    ///
    /// Handled entirely here (walking `head`/`body` directly) rather than via
    /// per-part visitor methods, so the renderer depends only on the table's
    /// public structure.
    /// - Parameter table: (`Table`) The table node.
    /// - Returns: (`String`) A complete `<table>` element.
    public mutating func visitTable(_ table: Table) -> String {
        var html = "<table>\n<thead>\n<tr>"
        for cell in table.head.cells {
            html += "<th>\(renderChildren(of: cell))</th>"
        }
        html += "</tr>\n</thead>\n<tbody>\n"
        for row in table.body.rows {
            html += "<tr>"
            for cell in row.cells {
                html += "<td>\(renderChildren(of: cell))</td>"
            }
            html += "</tr>\n"
        }
        html += "</tbody>\n</table>\n"
        return html
    }

    // MARK: - Helpers

    /// HTML-escapes the characters that are unsafe in text/attribute contexts.
    /// - Parameter string: (`String`) Raw text to escape.
    /// - Returns: (`String`) The text with `&`, `<`, `>`, and `"` replaced by entities.
    private func escape(_ string: String) -> String {
        var out = string
        out = out.replacingOccurrences(of: "&", with: "&amp;")
        out = out.replacingOccurrences(of: "<", with: "&lt;")
        out = out.replacingOccurrences(of: ">", with: "&gt;")
        out = out.replacingOccurrences(of: "\"", with: "&quot;")
        return out
    }

    /// Wraps a rendered HTML body in a complete, styled, standalone document.
    /// - Parameters:
    ///   - title: (`String`) The page title (escaped into `<title>`).
    ///   - body: (`String`) The already-rendered HTML body fragment.
    /// - Returns: (`String`) A full HTML5 document with embedded CSS.
    private static func page(title: String, body: String) -> String {
        let safeTitle = title
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(safeTitle)</title>
        <style>
        :root { color-scheme: light dark; }
        body {
          font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
          line-height: 1.6;
          max-width: 760px;
          margin: 2.5rem auto;
          padding: 0 1.25rem 4rem;
          color: #1d1d1f;
          background: #ffffff;
        }
        h1, h2, h3, h4 { line-height: 1.25; margin-top: 2rem; }
        h1 { font-size: 2rem; border-bottom: 1px solid #e5e5e7; padding-bottom: .4rem; }
        h2 { font-size: 1.5rem; border-bottom: 1px solid #eeeef0; padding-bottom: .3rem; }
        a { color: #0066cc; }
        code {
          font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
          font-size: .9em;
          background: #f5f5f7;
          padding: .15em .35em;
          border-radius: 4px;
        }
        pre {
          background: #f5f5f7;
          padding: 1rem;
          border-radius: 8px;
          overflow-x: auto;
        }
        pre code { background: none; padding: 0; }
        blockquote {
          margin: 1rem 0;
          padding: .4rem 1rem;
          border-left: 4px solid #d2d2d7;
          color: #515154;
          background: #fafafa;
        }
        table { border-collapse: collapse; width: 100%; margin: 1rem 0; }
        th, td { border: 1px solid #d2d2d7; padding: .5rem .75rem; text-align: left; vertical-align: top; }
        th { background: #f5f5f7; }
        hr { border: none; border-top: 1px solid #e5e5e7; margin: 2rem 0; }
        @media (prefers-color-scheme: dark) {
          body { color: #f5f5f7; background: #1d1d1f; }
          h1 { border-bottom-color: #3a3a3c; }
          h2 { border-bottom-color: #2c2c2e; }
          a { color: #4aa3ff; }
          code, pre { background: #2c2c2e; }
          blockquote { border-left-color: #48484a; color: #c7c7cc; background: #262628; }
          th, td { border-color: #3a3a3c; }
          th { background: #2c2c2e; }
          hr { border-top-color: #3a3a3c; }
        }
        </style>
        </head>
        <body>
        \(body)</body>
        </html>
        """
    }
}
