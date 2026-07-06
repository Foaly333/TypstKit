//
//  TypstEditorController.swift
//  TypstEditorKit
//
//  @Observable Controller fuer den Typst-Texteditor:
//  Syntax-Highlighting, Einrueckungs-Formatierung und Base64-Maskierung.
//
//  KI-Generierung ist bewusst NICHT Teil des Kits — Apps koennen eigene
//  Generierung ueber das extraMenuItems-API des TypstEditor anbinden.
//

import SwiftUI

@Observable
public final class TypstEditorController {

    public init() {}

    // MARK: - Syntax Highlight

    public func updateLetConstraint(on text: inout AttributedString, selection: inout AttributedTextSelection) {
        // Alle Ranges von Woertern sammeln, die mit '#' beginnen
        var ranges = RangeSet<AttributedString.Index>()
        let chars = text.characters

        var idx = chars.startIndex
        while idx < chars.endIndex {
            let ch = chars[idx]
            if ch == "#" {
                let start = idx
                var end = chars.index(after: idx)
                while end < chars.endIndex {
                    let c = chars[end]
                    if c.isLetter || c.isNumber || c == "_" {
                        end = chars.index(after: end)
                    } else {
                        break
                    }
                }
                if end > chars.index(after: start) {
                    ranges.insert(contentsOf: start..<end)
                }
                idx = end
            } else {
                idx = chars.index(after: idx)
            }
        }

        text.transform(updating: &selection) { t in
            t.typstCode = nil
            t[ranges].typstCode = "hashWord"
        }
    }

    // MARK: - Indentation Formatting

    /// Einrückungseinheit (2 Leerzeichen – Typst-Community-Standard).
    private static let indentUnit = "  "

    /// Formatiert Typst-Quelltext für bessere Lesbarkeit.
    ///
    /// Angewandte Regeln:
    /// 1. Konsistente Einrückung mit 2 Leerzeichen je Verschachtelungstiefe.
    /// 2. Klammern `()`, `[]`, `{}` werden zusammen gezählt; mehrere Klammern pro Zeile
    ///    ergeben ein Netto-Delta.
    /// 3. Klammern innerhalb von Strings (`"..."` mit `\"`-Escape) und nach
    ///    Line-Comments (`//`) werden ignoriert.
    /// 4. Schließende Klammern am Zeilenanfang verringern die Einrückung dieser Zeile.
    /// 5. Trailing-Whitespace wird entfernt.
    /// 6. Mehrere aufeinanderfolgende Leerzeilen werden auf eine reduziert;
    ///    führende und abschließende Leerzeilen entfallen.
    public func formattedIndent(from input: String) -> String {
        let rawLines = input.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline })
        var output: [String] = []
        var indentLevel = 0
        // Unterdrückt führende Leerzeilen
        var previousBlank = true

        for rawLine in rawLines {
            let trimmed = String(rawLine).trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                if !previousBlank {
                    output.append("")
                }
                previousBlank = true
                continue
            }
            previousBlank = false

            let analysis = bracketAnalysis(of: trimmed)

            // Zeilen, die mit schließender Klammer beginnen, gehen vor dem Schreiben
            // entsprechend zurück.
            let effectiveIndent = max(0, indentLevel - analysis.leadingClose)
            let prefix = String(repeating: Self.indentUnit, count: effectiveIndent)
            output.append(prefix + trimmed)

            indentLevel = max(0, indentLevel + analysis.delta)
        }

        // Abschließende Leerzeilen entfernen
        while let last = output.last, last.isEmpty {
            output.removeLast()
        }

        return output.joined(separator: "\n")
    }

    /// Analysiert eine bereits getrimmte Zeile auf Klammern.
    /// - Returns:
    ///   - `delta`: Netto-Saldo öffnender minus schließender Klammern (für die nächste Zeile).
    ///   - `leadingClose`: Anzahl der schließenden Klammern, die direkt am Anfang
    ///     der Zeile stehen (vor jeglichem nicht-schließendem Inhalt). Spaces dazwischen
    ///     sind erlaubt.
    /// Strings (`"..."`) und Line-Comments (`//`) werden ignoriert.
    private func bracketAnalysis(of line: String) -> (delta: Int, leadingClose: Int) {
        var delta = 0
        var leadingClose = 0
        var sawContent = false
        var inString = false

        var i = line.startIndex
        while i < line.endIndex {
            let c = line[i]
            let next = line.index(after: i)

            if inString {
                if c == "\\", next < line.endIndex {
                    // Escape: nächstes Zeichen überspringen
                    i = line.index(after: next)
                    continue
                }
                if c == "\"" {
                    inString = false
                }
                i = next
                continue
            }

            // Line-Comment: Rest der Zeile ignorieren
            if c == "/", next < line.endIndex, line[next] == "/" {
                break
            }

            switch c {
            case "\"":
                inString = true
                sawContent = true
            case "[", "{", "(":
                delta += 1
                sawContent = true
            case "]", "}", ")":
                delta -= 1
                if !sawContent {
                    leadingClose += 1
                }
            case " ", "\t":
                break
            default:
                sawContent = true
            }

            i = next
        }

        return (delta, leadingClose)
    }

    /// Komfort-Wrapper: formatiert direkt einen `AttributedString`.
    public func formatEditorText(from text: AttributedString) -> AttributedString {
        let plain = String(text.characters)
        let formatted = formattedIndent(from: plain)
        return AttributedString(formatted)
    }

    // MARK: - Base64 Maskierung / Tokenisierung

    /// Regex, das längere Base64-Inhalte in Anführungszeichen findet.
    /// Beispiel: "AAAA....==" (mind. 200 Zeichen)
    private static let base64Regex: NSRegularExpression = {
        let pattern = #""([A-Za-z0-9+/=\s]{200,})""#
        return try! NSRegularExpression(pattern: pattern, options: [])
    }()

    /// Regex, das Zeilen wie `#let imageCode = "..."` erkennt und den Inhalt in Anführungszeichen erfasst
    /// Beispiel: #let imageCode = "AAAA....=="
    private static let base64LetAssignmentRegex: NSRegularExpression = {
        // Erlaubt optionale Whitespaces, beliebige Variablennamen und erfasst den String-Inhalt in Gruppe 1
        let pattern = #"(?m)^\s*#let\s+[A-Za-z_][A-Za-z0-9_]*\s*=\s*\"([A-Za-z0-9+/=\s]{200,})\""#
        return try! NSRegularExpression(pattern: pattern, options: [])
    }()

    private static let tokenPrefix = "__TYPST_BASE64_TOKEN_"
    private static let tokenSuffix = "__"

    public static func token(for index: Int) -> String {
        return "\(tokenPrefix)\(index)\(tokenSuffix)"
    }

    public static func index(from token: String) -> Int? {
        guard token.hasPrefix(tokenPrefix),
              token.hasSuffix(tokenSuffix) else { return nil }
        let middle = token.dropFirst(tokenPrefix.count).dropLast(tokenSuffix.count)
        return Int(middle)
    }

    public static func placeholder(forToken token: String) -> String {
        if let idx = index(from: token) {
            return "[Bild \(idx + 1) – Base64 ausgeblendet]"
        } else {
            return "[Bild – Base64 ausgeblendet]"
        }
    }

    /// Sucht Base64-Inhalte und ersetzt sie durch Tokens.
    /// - Returns: (tokenized: String mit Tokens, mapping: token -> Base64-String)
    public func extractBase64Tokens(from full: String) -> (tokenized: String, mapping: [String: String]) {
        // Sichere Tokenisierung in zwei Durchgaengen auf demselben String.
        // Pass 1: `#let name = "<base64>"`-Zuweisungen.
        // Pass 2: generische Base64-Strings in Anfuehrungszeichen.
        var current = full as NSString
        var mapping: [String: String] = [:]
        var tokenIndex = 0

        // Ersetzt Matches fuer ein gegebenes Regex auf dem aktuellen String.
        func replaceMatches(using regex: NSRegularExpression) {
            let fullRange = NSRange(location: 0, length: current.length)
            let matches = regex.matches(in: current as String, options: [], range: fullRange)
            // Von hinten ersetzen, damit fruehere Ranges gueltig bleiben
            for match in matches.reversed() {
                // Base64-Inhalt wird bei beiden Regexes in Gruppe 1 erfasst
                guard match.numberOfRanges >= 2 else { continue }
                let captureRange = match.range(at: 1)
                guard NSMaxRange(captureRange) <= current.length else { continue }
                let base64Chunk = current.substring(with: captureRange)

                let token = Self.token(for: tokenIndex)
                mapping[token] = base64Chunk
                tokenIndex += 1

                current = current.replacingCharacters(in: captureRange, with: token) as NSString
            }
        }

        // 1) #let-Zuweisungen zuerst ersetzen
        replaceMatches(using: Self.base64LetAssignmentRegex)
        // 2) Dann generische Base64-Strings
        replaceMatches(using: Self.base64Regex)

        return (tokenized: current as String, mapping: mapping)
    }

    /// Ersetzt Tokens durch lesbare Platzhalter (nur Anzeige).
    public func tokenizedToDisplay(_ tokenized: String, mapping: [String: String]) -> String {
        var result = tokenized
        for token in mapping.keys {
            let placeholder = Self.placeholder(forToken: token)
            result = result.replacingOccurrences(of: token, with: placeholder)
        }
        return result
    }

    /// Ersetzt Platzhalter wieder zurück in Tokens.
    public func displayToTokenized(_ display: String, mapping: [String: String]) -> String {
        var result = display
        for token in mapping.keys {
            let placeholder = Self.placeholder(forToken: token)
            result = result.replacingOccurrences(of: placeholder, with: token)
        }
        return result
    }

    /// Ersetzt Tokens durch den originalen Base64-Code.
    public func restoreBase64(from tokenized: String, mapping: [String: String]) -> String {
        var result = tokenized
        for (token, base64) in mapping {
            result = result.replacingOccurrences(of: token, with: base64)
        }
        return result
    }
}
