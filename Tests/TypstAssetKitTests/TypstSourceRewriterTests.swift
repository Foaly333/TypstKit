//
//  TypstSourceRewriterTests.swift
//  TypstAssetKitTests
//

import Foundation
import Testing

@testable import TypstAssetKit

@Suite("Quelltext-Ersetzung ueber Ranges")
struct TypstSourceRewriterTests {

    @Test("Ohne Ersetzungen bleibt der Quelltext identisch")
    func returnsSourceUnchanged() {
        let source = "= Titel\nText mit https://example.de/seite"
        #expect(TypstSourceRewriter.apply([], to: source) == source)
    }

    @Test("Nur die angegebene Fundstelle wird ersetzt")
    func replacesOnlyTheGivenRange() {
        let source = #"#let u = "https://x/f.png" — siehe https://x/f.png"#
        let literal = source.range(of: "https://x/f.png")!   // das erste Vorkommen
        let result = TypstSourceRewriter.apply(
            [TypstSourceReplacement(range: literal, text: "__web__/f.png")],
            to: source
        )
        #expect(result == #"#let u = "__web__/f.png" — siehe https://x/f.png"#)
    }

    @Test("Mehrere Fundstellen bleiben trotz Laengenaenderung korrekt")
    func appliesMultipleReplacementsBackToFront() {
        let source = "aXXXbXXXc"
        let first = source.range(of: "XXX")!
        let second = source.range(of: "XXX", range: first.upperBound..<source.endIndex)!
        let result = TypstSourceRewriter.apply(
            [
                TypstSourceReplacement(range: first, text: "1"),
                TypstSourceReplacement(range: second, text: "22222"),
            ],
            to: source
        )
        #expect(result == "a1b22222c")
    }

    @Test("Reihenfolge der Ersetzungen spielt keine Rolle")
    func orderOfReplacementsDoesNotMatter() {
        let source = "aXXXbXXXc"
        let first = source.range(of: "XXX")!
        let second = source.range(of: "XXX", range: first.upperBound..<source.endIndex)!
        let result = TypstSourceRewriter.apply(
            [
                TypstSourceReplacement(range: second, text: "22222"),
                TypstSourceReplacement(range: first, text: "1"),
            ],
            to: source
        )
        #expect(result == "a1b22222c")
    }

    @Test("Ueberlappende Ranges beschaedigen den Quelltext nicht")
    func skipsOverlappingRanges() {
        let source = "abcdef"
        let outer = source.startIndex..<source.index(source.startIndex, offsetBy: 4)
        let inner = source.index(source.startIndex, offsetBy: 2)..<source.index(source.startIndex, offsetBy: 5)
        let result = TypstSourceRewriter.apply(
            [
                TypstSourceReplacement(range: outer, text: "X"),
                TypstSourceReplacement(range: inner, text: "Y"),
            ],
            to: source
        )
        // Die weiter hinten liegende Ersetzung gewinnt, die ueberlappende entfaellt.
        #expect(result == "abYf")
    }
}
