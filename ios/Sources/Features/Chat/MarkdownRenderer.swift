// ============================================================
// MarkdownRenderer - parser de markdown a AttributedString
// Soporta headings, listas (ordered/unordered), bold, italic,
// code inline, code blocks, blockquotes, separadores y parrafos.
// No usa dependencias externas: solo Foundation + AttributedString.
// ============================================================

import Foundation
import SwiftUI

/// Bloque de contenido parseado del markdown.
enum MarkdownBlock: Identifiable {
    case heading(level: Int, text: String)
    case paragraph(text: String)
    case listItem(text: String, ordered: Bool, number: Int)
    case codeBlock(language: String?, code: String)
    case blockquote(text: String)
    case divider
    case table(headers: [String], rows: [[String]])

    var id: String {
        switch self {
        case .heading(let l, let t): return "h\(l)-\(t)"
        case .paragraph(let t): return "p-\(t)"
        case .listItem(let t, let o, let n): return "li-\(o)-\(n)-\(t)"
        case .codeBlock(let lang, let c): return "code-\(lang ?? "")-\(c.prefix(20))"
        case .blockquote(let t): return "bq-\(t)"
        case .divider: return "hr"
        case .table(let h, let r): return "table-\(h.joined())-\(r.count)"
        }
    }
}

enum MarkdownRenderer {
    /// Parsea markdown en una lista de bloques.
    static func parse(_ raw: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = raw.components(separatedBy: "\n")
        var i = 0
        var orderedCounter = 0

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Linea vacia: separador entre bloques
            if trimmed.isEmpty {
                orderedCounter = 0
                i += 1
                continue
            }

            // Code block: ```lang ... ```
            if trimmed.hasPrefix("```") {
                let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                i += 1
                while i < lines.count {
                    let cl = lines[i]
                    if cl.trimmingCharacters(in: .whitespaces) == "```" {
                        i += 1
                        break
                    }
                    codeLines.append(cl)
                    i += 1
                }
                blocks.append(.codeBlock(
                    language: lang.isEmpty ? nil : lang,
                    code: codeLines.joined(separator: "\n")
                ))
                continue
            }

            // Divider: --- o *** o ___
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                blocks.append(.divider)
                orderedCounter = 0
                i += 1
                continue
            }

            // Heading: # ## ### #### ##### ######
            if let level = headingLevel(trimmed) {
                let text = trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                blocks.append(.heading(level: level, text: String(text)))
                orderedCounter = 0
                i += 1
                continue
            }

            // Blockquote: > text
            if trimmed.hasPrefix(">") {
                var quoteLines: [String] = []
                while i < lines.count {
                    let l = lines[i].trimmingCharacters(in: .whitespaces)
                    if l.hasPrefix(">") {
                        quoteLines.append(String(l.dropFirst().trimmingCharacters(in: .whitespaces)))
                        i += 1
                    } else if l.isEmpty {
                        i += 1
                        break
                    } else {
                        break
                    }
                }
                blocks.append(.blockquote(text: quoteLines.joined(separator: "\n")))
                orderedCounter = 0
                continue
            }

            // Ordered list: "1. item" / "2. item"
            if let match = orderedListMatch(trimmed) {
                orderedCounter = match.number
                blocks.append(.listItem(text: match.text, ordered: true, number: match.number))
                i += 1
                continue
            }

            // Unordered list: "- item" / "* item" / "+ item"
            if let text = unorderedListMatch(trimmed) {
                blocks.append(.listItem(text: text, ordered: false, number: 0))
                orderedCounter = 0
                i += 1
                continue
            }

            // Tabla: linea con | separadores
            if trimmed.contains("|") && trimmed.hasPrefix("|") {
                var tableLines: [String] = []
                while i < lines.count {
                    let l = lines[i].trimmingCharacters(in: .whitespaces)
                    if l.contains("|") && l.hasPrefix("|") {
                        tableLines.append(l)
                        i += 1
                    } else {
                        break
                    }
                }
                if let table = parseTable(tableLines) {
                    blocks.append(table)
                    orderedCounter = 0
                    continue
                }
            }

            // Parrafo: agrupar lineas consecutivas no vacias
            var paraLines: [String] = [trimmed]
            i += 1
            while i < lines.count {
                let l = lines[i].trimmingCharacters(in: .whitespaces)
                if l.isEmpty { break }
                // Si la siguiente linea es otro tipo de bloque, parar
                if headingLevel(l) != nil { break }
                if l.hasPrefix("```") { break }
                if l.hasPrefix(">") { break }
                if orderedListMatch(l) != nil { break }
                if unorderedListMatch(l) != nil { break }
                if l == "---" || l == "***" || l == "___" { break }
                paraLines.append(l)
                i += 1
            }
            blocks.append(.paragraph(text: paraLines.joined(separator: " ")))
            orderedCounter = 0
        }

        return blocks
    }

    // MARK: - Helpers de parseo por linea

    private static func headingLevel(_ line: String) -> Int? {
        var count = 0
        for c in line {
            if c == "#" { count += 1 } else { break }
        }
        if count > 0 && count <= 6 {
            let after = line.drop(while: { $0 == "#" })
            // Debe haber un espacio despues de los #
            if after.first == " " || after.first == "\t" {
                return count
            }
        }
        return nil
    }

    private struct OrderedMatch {
        let number: Int
        let text: String
    }

    private static func orderedListMatch(_ line: String) -> OrderedMatch? {
        // Patron: "1. " o "10. "
        var numStr = ""
        for c in line {
            if c.isNumber { numStr.append(c) }
            else { break }
        }
        guard let n = Int(numStr), n > 0 else { return nil }
        let rest = line.dropFirst(numStr.count)
        if rest.hasPrefix(".") {
            let after = rest.dropFirst().trimmingCharacters(in: .whitespaces)
            if !after.isEmpty {
                return OrderedMatch(number: n, text: after)
            }
        }
        return nil
    }

    private static func unorderedListMatch(_ line: String) -> String? {
        guard let first = line.first else { return nil }
        if first == "-" || first == "*" || first == "+" {
            let rest = line.dropFirst().trimmingCharacters(in: .whitespaces)
            // Evitar confundir divider "---" con lista
            if first == "-" && rest.hasPrefix("--") { return nil }
            if !rest.isEmpty {
                return rest
            }
        }
        return nil
    }

    // MARK: - Tablas

    private static func parseTable(_ lines: [String]) -> MarkdownBlock? {
        guard lines.count >= 2 else { return nil }
        // La segunda linea debe ser el separador: |---|---|
        let separatorLine = lines[1]
        let separatorCells = splitTableRow(separatorLine)
        let isSeparator = separatorCells.allSatisfy { cell in
            let trimmed = cell.trimmingCharacters(in: .whitespaces)
            return trimmed.allSatisfy { $0 == "-" || $0 == ":" } && trimmed.contains("-")
        }
        guard isSeparator else { return nil }

        let headers = splitTableRow(lines[0])
        var rows: [[String]] = []
        for line in lines.dropFirst(2) {
            rows.append(splitTableRow(line))
        }
        return .table(headers: headers, rows: rows)
    }

    private static func splitTableRow(_ line: String) -> [String] {
        let cleaned = line.trimmingCharacters(in: .whitespaces)
        // Quitar | del inicio y final
        var inner = cleaned
        if inner.hasPrefix("|") { inner = String(inner.dropFirst()) }
        if inner.hasSuffix("|") { inner = String(inner.dropLast()) }
        return inner.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    // MARK: - Render a AttributedString

    /// Convierte texto inline con **bold**, *italic*, `code`, ~~strike~~ y
    /// [links](url) a AttributedString con atributos SwiftUI.
    static func renderInline(_ text: String, baseFont: Font = .body) -> AttributedString {
        // AttributedString.markdown soporta inline (no extended) pero no
        // maneja bien ~strike~. Lo usamos con interpretedSyntax .inlineOnly
        // que soporta bold, italic, code, links.
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: true,
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        if let attr = try? AttributedString(markdown: text, options: options) {
            return attr
        }
        return AttributedString(text)
    }
}

// MARK: - Vista SwiftUI que renderiza los bloques

struct MarkdownView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(MarkdownRenderer.parse(text).enumerated()), id: \.offset) { _, block in
                renderBlock(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func renderBlock(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            headingView(level: level, text: text)

        case .paragraph(let text):
            Text(MarkdownRenderer.renderInline(text))
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .listItem(let text, let ordered, let number):
            HStack(alignment: .top, spacing: 6) {
                if ordered {
                    Text("\(number).")
                        .font(.body.weight(.medium))
                        .foregroundStyle(.secondary)
                } else {
                    Text("\u{2022}")
                        .font(.body.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                Text(MarkdownRenderer.renderInline(text))
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .codeBlock(let lang, let code):
            VStack(alignment: .leading, spacing: 0) {
                if let lang, !lang.isEmpty {
                    HStack {
                        Text(lang.uppercased())
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
                    .padding(.bottom, 4)
                }
                Text(code)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            }
            .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
            .frame(maxWidth: .infinity, alignment: .leading)

        case .blockquote(let text):
            HStack(alignment: .top, spacing: 8) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.3))
                    .frame(width: 3)
                Text(MarkdownRenderer.renderInline(text))
                    .font(.body.italic())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .divider:
            Divider()
                .padding(.vertical, 4)

        case .table(let headers, let rows):
            tableView(headers: headers, rows: rows)
        }
    }

    @ViewBuilder
    private func tableView(headers: [String], rows: [[String]]) -> some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 0) {
                ForEach(Array(headers.enumerated()), id: \.offset) { _, header in
                    Text(MarkdownRenderer.renderInline(header, baseFont: .subheadline.weight(.semibold)))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                }
            }
            .background(Color(.tertiarySystemBackground))
            Divider()
            // Rows
            ForEach(Array(rows.enumerated()), id: \.offset) { rowIdx, row in
                HStack(spacing: 0) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        Text(MarkdownRenderer.renderInline(cell))
                            .font(.subheadline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                    }
                }
                .background(rowIdx % 2 == 0 ? Color.clear : Color(.tertiarySystemBackground).opacity(0.3))
                if rowIdx < rows.count - 1 {
                    Divider()
                }
            }
        }
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 0.5)
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func headingView(level: Int, text: String) -> some View {
        let font: Font = switch level {
        case 1: .title.weight(.bold)
        case 2: .title2.weight(.bold)
        case 3: .title3.weight(.semibold)
        case 4: .headline.weight(.semibold)
        case 5: .subheadline.weight(.semibold)
        default: .body.weight(.semibold)
        }
        Text(MarkdownRenderer.renderInline(text))
            .font(font)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, level <= 2 ? 4 : 2)
    }
}
