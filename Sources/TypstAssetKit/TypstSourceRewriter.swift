//
//  TypstSourceRewriter.swift
//  TypstAssetKit
//
//  Ersetzt einzelne Fundstellen in einem Typst-Quelltext.
//
//  Der Grund fuer diesen Typ ist eine Klasse von Fehlern, die ein globales
//  `replacingOccurrences(of:with:)` unvermeidlich erzeugt: es hat keinen Begriff
//  davon, ob ein Vorkommen Code oder Fliesstext ist. Steht im Dokument
//  `#let host = "https://example.de"` und irgendwo im Fliesstext der Link
//  `https://example.de/seite`, dann schreibt ein globales Ersetzen auch den Link
//  um — lautlos, ohne Fehlermeldung.
//
//  Deshalb: Es werden ausschliesslich vorher ermittelte Ranges ersetzt.
//

import Foundation

/// Eine einzelne Ersetzung: welcher Bereich, welcher neue Text.
public struct TypstSourceReplacement: Sendable, Hashable {
    public let range: Range<String.Index>
    public let text: String

    public init(range: Range<String.Index>, text: String) {
        self.range = range
        self.text = text
    }
}

public enum TypstSourceRewriter {

    /// Wendet die Ersetzungen auf `source` an.
    ///
    /// Von hinten nach vorn, damit die noch offenen Ranges gueltig bleiben —
    /// jede Ersetzung verschiebt nur Indizes *hinter* sich.
    /// Ueberlappende Ranges werden verworfen (die weiter hinten gewinnt);
    /// beim Aufruf aus dem Resolver kann das nicht vorkommen, aber der Typ soll
    /// auch dann nichts kaputt machen, wenn es doch einmal so ist.
    public static func apply(
        _ replacements: [TypstSourceReplacement],
        to source: String
    ) -> String {
        guard !replacements.isEmpty else { return source }

        let ordered = replacements.sorted { $0.range.lowerBound > $1.range.lowerBound }

        var result = source
        var lastLowerBound: String.Index? = nil

        for replacement in ordered {
            if let lastLowerBound, replacement.range.upperBound > lastLowerBound { continue }
            result.replaceSubrange(replacement.range, with: replacement.text)
            lastLowerBound = replacement.range.lowerBound
        }

        return result
    }
}
