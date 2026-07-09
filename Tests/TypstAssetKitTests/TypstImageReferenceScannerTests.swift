//
//  TypstImageReferenceScannerTests.swift
//  TypstAssetKitTests
//

import Foundation
import Testing

@testable import TypstAssetKit

@Suite("Bildpfad-Erkennung")
struct TypstImageReferenceScannerTests {

    private let path = "img/11dde32c3e434fdcb438e9e3342d2250.png"

    // MARK: Direkter Aufruf (bestehendes Verhalten, darf nicht brechen)

    @Test("Pfad direkt im image-Aufruf")
    func findsDirectCall() {
        #expect(TypstImageReferenceScanner.references(in: #"#image("\#(path)")"#) == [path])
    }

    @Test("Pfad im image-Aufruf mit weiteren Argumenten")
    func findsDirectCallWithArguments() {
        #expect(TypstImageReferenceScanner.references(in: #"#image("\#(path)", width: 3cm)"#) == [path])
    }

    @Test("Web-URL direkt im image-Aufruf")
    func findsDirectWebCall() {
        let url = "https://example.com/foto.png"
        #expect(TypstImageReferenceScanner.references(in: #"#image("\#(url)")"#) == [url])
    }

    // MARK: `#let`-Bindung — die Ausgabe des Importers

    @Test("Pfad ueber eine #let-Bindung")
    func findsLetBinding() {
        let source = """
        #let imageControlFirstCode = "\(path)"
        #let imageControlFirst = image(imageControlFirstCode)
        """
        #expect(TypstImageReferenceScanner.references(in: source) == [path])
    }

    @Test("let ohne Doppelkreuz, im Code-Block")
    func findsBareLet() {
        let source = """
        #{
          let code = "\(path)"
          image(code)
        }
        """
        #expect(TypstImageReferenceScanner.references(in: source) == [path])
    }

    @Test("Web-URL ueber eine #let-Bindung")
    func findsLetBoundWebURL() {
        let url = "https://example.com/foto.png"
        #expect(TypstImageReferenceScanner.references(in: #"#let u = "\#(url)""#) == [url])
    }

    @Test("Bindestriche und Ziffern im Bezeichner")
    func findsBindingWithDashedIdentifier() {
        #expect(TypstImageReferenceScanner.references(in: #"#let logo-2 = "\#(path)""#) == [path])
    }

    // MARK: Abgrenzung

    @Test("`let` als Wortende matcht nicht doppelt")
    func doesNotMatchLetInsideWord() {
        // `outlet` enthaelt `let` — es darf genau ein Treffer entstehen, nicht zwei.
        #expect(TypstImageReferenceScanner.references(in: #"#let outlet = "\#(path)""#) == [path])
    }

    @Test("Ein Base64-Blob ist kein Pfad")
    func ignoresBase64Blob() {
        let blob = String(repeating: "A", count: 200_000)
        #expect(TypstImageReferenceScanner.references(in: #"#let code = "\#(blob)""#).isEmpty)
    }

    @Test("Dokumente ohne Bilder liefern nichts")
    func findsNothingWithoutImages() {
        #expect(TypstImageReferenceScanner.references(in: "= Titel\nNur Text.").isEmpty)
    }

    // MARK: Deduplizierung und Reihenfolge

    @Test("Derselbe Pfad in #let und image ergibt einen Eintrag")
    func deduplicatesAcrossForms() {
        let source = """
        #let code = "\(path)"
        #image("\(path)")
        """
        #expect(TypstImageReferenceScanner.references(in: source) == [path])
    }

    @Test("Mehrere unterschiedliche Pfade")
    func findsMultiplePaths() {
        let other = "img/00112233445566778899aabbccddeeff.jpg"
        let source = """
        #let a = "\(path)"
        #image("\(other)")
        """
        #expect(Set(TypstImageReferenceScanner.references(in: source)) == [path, other])
    }

    // MARK: Kandidaten, die der Resolver spaeter verwirft

    @Test("Nicht-Pfade werden als Kandidat gemeldet und spaeter gefiltert")
    func reportsNonPathCandidates() {
        // Der Scanner kennt den Typst-Wertebereich nicht — das ist Absicht.
        // `TypstImageResolver.processRef` verwirft alles ohne http(s):// oder img/.
        let refs = TypstImageReferenceScanner.references(in: #"#let titel = "Kapitel 1""#)
        #expect(refs == ["Kapitel 1"])
    }
}
