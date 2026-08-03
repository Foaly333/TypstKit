//
//  TypstWebImageResponseTests.swift
//  TypstAssetKitTests
//

import Foundation
import Testing

@testable import TypstAssetKit

@Suite("Annahme von Web-Ressourcen als Bild")
struct TypstWebImageResponseTests {

    private let html = Data("""
    <!DOCTYPE html>
    <html lang="de"><head><title>inf-schule</title></head><body>…</body></html>
    """.utf8)

    private let svg = Data(#"<?xml version="1.0"?>\#n<svg xmlns="http://www.w3.org/2000/svg"/>"#.utf8)

    // MARK: Echte Bilder

    @Test("PNG mit passendem Content-Type")
    func acceptsPNG() {
        #expect(
            TypstWebImageResponse.imagePath(
                forURL: "https://x/f.png",
                contentType: "image/png",
                data: Fixtures.onePixelPNG
            ) == "__web__/f.png"
        )
    }

    @Test("Bild ohne Content-Type wird an den Magic Bytes erkannt")
    func acceptsImageWithoutContentType() {
        #expect(
            TypstWebImageResponse.imagePath(
                forURL: "https://x/foto",
                contentType: nil,
                data: Fixtures.jpeg(byteCount: 64)
            ) == "__web__/foto.jpg"
        )
    }

    @Test("Falsche Endung wird durch das tatsaechliche Format ergaenzt")
    func appendsRealFormatExtension() {
        #expect(
            TypstWebImageResponse.imagePath(
                forURL: "https://x/foto.png",
                contentType: "image/jpeg",
                data: Fixtures.jpeg(byteCount: 64)
            ) == "__web__/foto.png.jpg"
        )
    }

    @Test("Query-Parameter landen nicht im Dateinamen")
    func ignoresQuery() {
        #expect(
            TypstWebImageResponse.imagePath(
                forURL: "https://x/f.png?v=2",
                contentType: "image/png",
                data: Fixtures.onePixelPNG
            ) == "__web__/f.png"
        )
    }

    @Test("Echtes SVG wird angenommen")
    func acceptsSVG() {
        #expect(
            TypstWebImageResponse.imagePath(forURL: "https://x/logo.svg", contentType: nil, data: svg)
                == "__web__/logo.svg"
        )
    }

    // MARK: Alles, was kein Bild ist

    @Test("HTML-Seite ist kein Bild — auch mit Bild-Endung in der URL")
    func rejectsHTML() {
        #expect(
            TypstWebImageResponse.imagePath(
                forURL: "https://x/f.png",
                contentType: "text/html; charset=utf-8",
                data: html
            ) == nil
        )
    }

    @Test("HTML ohne Content-Type wird nicht als SVG durchgewinkt")
    func rejectsHTMLWithoutContentType() {
        // `TypstImageFormat.sniff` erkennt SVG am fuehrenden `<` — eine
        // HTML-Seite faengt genauso an. Ohne die zweite Bestaetigung waere
        // jede Website ein „Bild".
        #expect(TypstWebImageResponse.imagePath(forURL: "https://x/seite", contentType: nil, data: html) == nil)
    }

    @Test("Host ohne Pfad wird verworfen")
    func rejectsHostWithoutPath() {
        // Der Auslöser des Fehlers: `#let host = "https://inf-schule.de"`.
        #expect(
            TypstWebImageResponse.imagePath(
                forURL: "https://inf-schule.de",
                contentType: "image/png",
                data: Fixtures.onePixelPNG
            ) == nil
        )
        #expect(
            TypstWebImageResponse.imagePath(
                forURL: "https://inf-schule.de/",
                contentType: "image/png",
                data: Fixtures.onePixelPNG
            ) == nil
        )
    }

    @Test("Beliebige Binaerdaten sind kein Bild")
    func rejectsArbitraryBytes() {
        #expect(
            TypstWebImageResponse.imagePath(
                forURL: "https://x/datei.png",
                contentType: "application/octet-stream",
                data: Data([0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07])
            ) == nil
        )
    }

    @Test("Trailing Slash: der letzte Pfadbestandteil zaehlt")
    func handlesTrailingSlash() {
        #expect(
            TypstWebImageResponse.imagePath(
                forURL: "https://x/bilder/",
                contentType: "image/png",
                data: Fixtures.onePixelPNG
            ) == "__web__/bilder.png"
        )
    }
}
