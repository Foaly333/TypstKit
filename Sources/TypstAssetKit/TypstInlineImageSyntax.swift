//
//  TypstInlineImageSyntax.swift
//  TypstAssetKit
//
//  Beschreibt, wie eingebettete Bilder im Typst-Quelltext aussehen.
//
//  Erkannt und erzeugt werden zwei Formen:
//
//    A) Zuweisung
//         #let imageCode = "iVBORw0KGgo…"
//         #image(base64.decode(imageCode))
//
//    B) direkter Aufruf
//         #image(base64.decode("iVBORw0KGgo…"))
//
//  Nach dem Import lauten sie:
//
//    A) #let imageCode = "img/3f2a….png"
//       #image(imageCode)
//    B) #image("img/3f2a….png")
//
//  Der Export bettet jeden Store-Pfad wieder als `base64.decode("…")` ein.
//  Aus A wird dabei die kanonische Form
//
//       #let imageCode = base64.decode("iVBOR…")
//       #image(imageCode)
//
//  — semantisch identisch zur Ausgangsform, und ab dann ein Fixpunkt:
//  Import und Export heben sich in beiden Richtungen exakt auf.
//

import Foundation

public struct TypstInlineImageSyntax: Sendable {
    /// Ab wie vielen Base64-Zeichen (ohne Whitespace) ein String-Literal als
    /// Bilddaten gilt. Kuerzere Strings bleiben unangetastet.
    public var minimumBase64Length: Int

    /// Name der Decode-Funktion, z.B. `base64.decode` aus `@preview/based`.
    public var decodeFunction: String

    /// Import-Zeile, die der Export voranstellt, falls sie fehlt.
    public var decodeImport: String

    /// Fragment, an dem der Export erkennt, dass der Import bereits vorhanden ist.
    public var decodeImportMarker: String

    public init(
        minimumBase64Length: Int = 200,
        decodeFunction: String = "base64.decode",
        decodeImport: String = #"#import "@preview/based:0.2.0": base64"#,
        decodeImportMarker: String = ": base64"
    ) {
        self.minimumBase64Length = minimumBase64Length
        self.decodeFunction = decodeFunction
        self.decodeImport = decodeImport
        self.decodeImportMarker = decodeImportMarker
    }

    public static let `default` = TypstInlineImageSyntax()

    /// `base64.decode(` als Bytes — der Kontext, den die Rewriter zurueckblicken.
    var decodeCallOpen: [UInt8] { Array((decodeFunction + "(").utf8) }
}

// MARK: - Zeichenklassen

@inline(__always)
func isIdentifierStart(_ byte: UInt8) -> Bool {
    (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) || byte == 0x5F
}

@inline(__always)
func isIdentifierByte(_ byte: UInt8) -> Bool {
    isIdentifierStart(byte) || (byte >= 0x30 && byte <= 0x39) || byte == 0x2D
}

@inline(__always)
func isInlineSpace(_ byte: UInt8) -> Bool {
    byte == 0x20 || byte == 0x09
}

/// Leerraum inklusive Zeilenumbruechen. Aufrufe wie
/// `base64.decode(\n  "…"\n)` sind gueltiges Typst und muessen erkannt werden.
@inline(__always)
func isAnyWhitespace(_ byte: UInt8) -> Bool {
    isInlineSpace(byte) || byte == 0x0A || byte == 0x0D
}

extension Array where Element == UInt8 {
    func hasSuffix(_ suffix: [UInt8]) -> Bool {
        guard count >= suffix.count else { return false }
        return Array(self[(count - suffix.count)...]) == suffix
    }
}

/// Erkennt am Ende von `bytes` ein `#let <ident> =` bzw. `let <ident> =`
/// und liefert den Bezeichner.
///
/// Wird auf einen kurzen Kontextpuffer angewandt, nie auf das ganze Dokument.
func matchLetAssignmentSuffix(_ bytes: [UInt8]) -> String? {
    var index = bytes.count - 1

    func skipSpaces() {
        while index >= 0, isAnyWhitespace(bytes[index]) { index -= 1 }
    }

    skipSpaces()
    guard index >= 0, bytes[index] == 0x3D else { return nil } // '='
    index -= 1
    skipSpaces()

    var identifier: [UInt8] = []
    while index >= 0, isIdentifierByte(bytes[index]) {
        identifier.append(bytes[index])
        index -= 1
    }
    // `identifier` steht rueckwaerts; das letzte Element ist das erste Zeichen.
    guard let firstChar = identifier.last, isIdentifierStart(firstChar) else { return nil }
    identifier.reverse()

    guard index >= 0, isAnyWhitespace(bytes[index]) else { return nil }
    skipSpaces()

    guard endsWithLetKeyword(bytes, at: index) else { return nil }
    return String(decoding: identifier, as: UTF8.self)
}

/// Prueft, ob `bytes[...index]` auf das Schluesselwort `let` endet — mit
/// gueltiger Grenze davor (`#`, Zeilenanfang, Klammer, …).
private func endsWithLetKeyword(_ bytes: [UInt8], at index: Int) -> Bool {
    let keyword = Array("let".utf8)
    guard index >= keyword.count - 1 else { return false }

    let start = index - keyword.count + 1
    guard Array(bytes[start...index]) == keyword else { return false }

    let boundary = start - 1
    if boundary < 0 { return true }
    if bytes[boundary] == 0x23 { return true }          // '#let'
    return !isIdentifierByte(bytes[boundary])           // schliesst z.B. "outlet" aus
}
