// SPDX-License-Identifier: Apache-2.0
//
//  main.swift
//  md2html
//
//  Tiny build-time command-line tool: reads a Markdown file and writes a
//  standalone, styled HTML page. Used by the build scripts to render the
//  project manual (assets/MANUAL.md) into MANUAL.html for end users, while the
//  Markdown source stays the maintainable copy in the repository.
//
//  Usage:
//    md2html <input.md> <output.html> [page-title]
//

import Foundation
import MarkdownHTML

/// Writes a message to standard error.
/// - Parameter message: (`String`) The line to emit (a newline is appended).
func warn(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    warn("usage: md2html <input.md> <output.html> [page-title]")
    exit(2)
}

let inputPath = arguments[1]
let outputPath = arguments[2]
let title = arguments.count >= 4 ? arguments[3] : "RunShortcutsMCP — User Guide"

do {
    let markdown = try String(contentsOfFile: inputPath, encoding: .utf8)
    let html = MarkdownHTMLRenderer.renderPage(markdown: markdown, title: title)
    try Data(html.utf8).write(to: URL(fileURLWithPath: outputPath))
    print("md2html: wrote \(outputPath)")
} catch {
    warn("md2html: \(error)")
    exit(1)
}
