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

    // MARK: Wortgrenze vor `image(`

    @Test("Funktionen, deren Name auf image endet, matchen nicht")
    func ignoresSuffixedFunctionNames() {
        #expect(TypstImageReferenceScanner.references(in: #"#qrimage("https://x/y")"#).isEmpty)
        #expect(TypstImageReferenceScanner.references(in: #"#myimage("img/a.png")"#).isEmpty)
    }

    @Test("Methodenaufruf auf einem Objekt matcht nicht")
    func ignoresMethodCall() {
        #expect(TypstImageReferenceScanner.references(in: #"#foo.image("img/a.png")"#).isEmpty)
    }

    @Test("image am Zeilenanfang matcht")
    func findsCallAtLineStart() {
        let source = """
        #{
        image("img/a.png")
        }
        """
        #expect(TypstImageReferenceScanner.references(in: source) == ["img/a.png"])
    }

    // MARK: Fundstellen mit Range

    @Test("scan liefert die Range des Literals ohne Anfuehrungszeichen")
    func scanReportsLiteralRange() {
        let source = #"#image("\#(path)", width: 3cm)"#
        let refs = TypstImageReferenceScanner.scan(source)
        #expect(refs.count == 1)
        #expect(refs.first?.path == path)
        #expect(refs.first.map { String(source[$0.range]) } == path)
    }

    @Test("Derselbe Pfad in #let und image ergibt zwei Fundstellen")
    func scanKeepsEveryOccurrence() {
        let source = """
        #let code = "\(path)"
        #image("\(path)")
        """
        let refs = TypstImageReferenceScanner.scan(source)
        #expect(refs.count == 2)
        #expect(refs.allSatisfy { $0.path == path })
        #expect(refs.allSatisfy { String(source[$0.range]) == path })
        // aufsteigend nach Position sortiert
        #expect(refs[0].range.lowerBound < refs[1].range.lowerBound)
    }

    @Test("Ein Host im #let ist ein Kandidat, der Link im Fliesstext nicht")
    func scanIgnoresProseLinks() {
        // Der Auslöser des Fehlers: der Host steht als Literal im Template,
        // im Fliesstext stehen nackte Links, die damit anfangen.
        let source = """
        #let host = "https://inf-schule.de"

        Quelle: https://inf-schule.de/awbs (16.4.1.1)
        """
        let refs = TypstImageReferenceScanner.scan(source)
        #expect(refs.count == 1)
        #expect(refs.first?.path == "https://inf-schule.de")
        #expect(refs.first.map { String(source[$0.range]) } == "https://inf-schule.de")
    }

    @Test("Dokument ohne Bilder liefert keine Fundstellen")
    func scanFindsNothingWithoutImages() {
        #expect(TypstImageReferenceScanner.scan("= Titel\nNur Text.").isEmpty)
    }
}
