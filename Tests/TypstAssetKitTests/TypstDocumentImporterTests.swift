//
//  TypstDocumentImporterTests.swift
//  TypstAssetKitTests
//

import Foundation
import Testing

@testable import TypstAssetKit

@Suite("Dokument-Import")
struct TypstDocumentImporterTests {

    // MARK: Die beiden Inline-Formen

    @Test("Form A: #let-Zuweisung samt Verwendung wird umgeschrieben")
    func rewritesLetAssignmentForm() throws {
        let temp = try TemporaryDirectory()
        let source = """
        \(Fixtures.importLine)

        #let imageCode = "\(Fixtures.onePixelPNGBase64)"

        #figure(image(base64.decode(imageCode)), caption: [Ein Punkt])
        """

        let (result, summary) = try TypstDocumentImporter.importSource(
            source, store: temp.store, syntax: Fixtures.syntax
        )

        let ref = try #require(summary.assets.first)
        #expect(summary.didChange)
        #expect(summary.assets.count == 1)
        #expect(result == """
        \(Fixtures.importLine)

        #let imageCode = "\(ref.path)"

        #figure(image(imageCode), caption: [Ein Punkt])
        """)
        #expect(try temp.store.data(for: ref) == Fixtures.onePixelPNG)
    }

    @Test("Form B: direkter decode-Aufruf wird umgeschrieben")
    func rewritesDirectDecodeForm() throws {
        let temp = try TemporaryDirectory()
        let source = #"#image(base64.decode("\#(Fixtures.onePixelPNGBase64)"), width: 2cm)"#

        let (result, summary) = try TypstDocumentImporter.importSource(
            source, store: temp.store, syntax: Fixtures.syntax
        )

        let ref = try #require(summary.assets.first)
        #expect(result == #"#image("\#(ref.path)", width: 2cm)"#)
        #expect(summary.didChange)
    }

    @Test("Beide Formen im selben Dokument")
    func handlesBothFormsTogether() throws {
        let temp = try TemporaryDirectory()
        let jpeg = Fixtures.jpeg(byteCount: 300).base64EncodedString()
        let source = """
        #let a = "\(Fixtures.onePixelPNGBase64)"
        #image(base64.decode(a))
        #image(base64.decode("\(jpeg)"))
        """

        let (result, summary) = try TypstDocumentImporter.importSource(
            source, store: temp.store, syntax: Fixtures.syntax
        )

        #expect(summary.assets.count == 2)
        #expect(result.contains("#let a = \"img/"))
        #expect(result.contains("#image(a)"))
        #expect(result.contains("#image(\"img/"))
        #expect(!result.contains("base64.decode"))
    }

    @Test("Dasselbe Bild zweimal ergibt eine Datei")
    func deduplicatesWithinDocument() throws {
        let temp = try TemporaryDirectory()
        let source = """
        #image(base64.decode("\(Fixtures.onePixelPNGBase64)"))
        #image(base64.decode("\(Fixtures.onePixelPNGBase64)"))
        """

        let (result, summary) = try TypstDocumentImporter.importSource(
            source, store: temp.store, syntax: Fixtures.syntax
        )

        #expect(summary.assets.count == 2)
        #expect(Set(summary.assets).count == 1)
        #expect(temp.fileCount(in: "img") == 1)

        let ref = try #require(summary.assets.first)
        #expect(result == """
        #image("\(ref.path)")
        #image("\(ref.path)")
        """)
    }

    // MARK: Byte-Erhaltung

    @Test("Dokumente ohne Base64 bleiben Byte fuer Byte gleich")
    func preservesDocumentsWithoutBase64() throws {
        let temp = try TemporaryDirectory()
        let source = #"""
        // Ein Kommentar mit "Anfuehrungszeichen" und base64.decode(foo)
        #let title = "Kurzer String"
        #let escaped = "er sagte \"hallo\" und ging"
        #let path = "img/nicht-wirklich-ein-hash.png"

        = #title
        Text mit ( Klammern ) und = Gleichheitszeichen.
        """#

        let (result, summary) = try TypstDocumentImporter.importSource(
            source, store: temp.store, syntax: Fixtures.syntax
        )

        #expect(result == source)
        #expect(!summary.didChange)
        #expect(summary.assets.isEmpty)
        #expect(temp.fileCount(in: "img") == 0)
    }

    @Test("Langes Base64, das kein Bild ist, bleibt unangetastet")
    func leavesNonImageBase64Alone() throws {
        let temp = try TemporaryDirectory()
        // 400 × 'A' dekodiert zu 300 Nullbytes — kein bekanntes Bildformat.
        let source = #"#let fontData = "\#(String(repeating: "A", count: 400))""#

        let (result, summary) = try TypstDocumentImporter.importSource(
            source, store: temp.store, syntax: Fixtures.syntax
        )

        #expect(result == source)
        #expect(!summary.didChange)
        #expect(temp.fileCount(in: "img") == 0)
    }

    @Test("Ungueltiges Base64 bleibt unangetastet")
    func leavesInvalidBase64Alone() throws {
        let temp = try TemporaryDirectory()
        // Beginnt wie Base64, endet aber mit einem Fremdzeichen.
        let source = #"#let x = "\#(String(repeating: "A", count: 400))ä""#

        let (result, summary) = try TypstDocumentImporter.importSource(
            source, store: temp.store, syntax: Fixtures.syntax
        )

        #expect(result == source)
        #expect(!summary.didChange)
    }

    @Test("Mehrzeiliger decode-Aufruf mit Literal")
    func handlesMultilineDirectCall() throws {
        let temp = try TemporaryDirectory()
        let source = """
        #image(base64.decode(
          "\(Fixtures.onePixelPNGBase64)"
        ))
        """

        let (result, summary) = try TypstDocumentImporter.importSource(
            source, store: temp.store, syntax: Fixtures.syntax
        )

        let ref = try #require(summary.assets.first)
        #expect(result == "#image(\"\(ref.path)\")")
    }

    @Test("Mehrzeiliger decode-Aufruf mit Bezeichner")
    func handlesMultilineIdentifierCall() throws {
        let temp = try TemporaryDirectory()
        let source = """
        #let logo = "\(Fixtures.onePixelPNGBase64)"
        #image(base64.decode(
          logo
        ))
        """

        let (result, summary) = try TypstDocumentImporter.importSource(
            source, store: temp.store, syntax: Fixtures.syntax
        )

        let ref = try #require(summary.assets.first)
        #expect(result == """
        #let logo = "\(ref.path)"
        #image(logo)
        """)
    }

    @Test("Ein unbenutzter Bezeichner wird nicht ausgepackt")
    func doesNotUnwrapUnknownIdentifier() throws {
        let temp = try TemporaryDirectory()
        let source = "#image(base64.decode(nichtDefiniert))"

        let (result, summary) = try TypstDocumentImporter.importSource(
            source, store: temp.store, syntax: Fixtures.syntax
        )

        #expect(result == source)
        #expect(!summary.didChange)
    }

    // MARK: Idempotenz

    @Test("Zweiter Import aendert nichts mehr")
    func isIdempotent() throws {
        let temp = try TemporaryDirectory()
        let source = """
        #let logo = "\(Fixtures.onePixelPNGBase64)"
        #image(base64.decode(logo))
        """

        let (once, firstSummary) = try TypstDocumentImporter.importSource(
            source, store: temp.store, syntax: Fixtures.syntax
        )
        let (twice, secondSummary) = try TypstDocumentImporter.importSource(
            once, store: temp.store, syntax: Fixtures.syntax
        )

        #expect(firstSummary.didChange)
        #expect(!secondSummary.didChange)
        #expect(twice == once)
        // Die Referenz wird beim zweiten Lauf weiterhin gemeldet — die GC braucht sie.
        #expect(secondSummary.assets == firstSummary.assets)
    }

    // MARK: Groesse

    @Test("Grosses Bild landet unversehrt im Store")
    func handlesLargeImage() throws {
        let temp = try TemporaryDirectory()
        let image = Fixtures.png(byteCount: 1_000_000)
        let source = #"#image(base64.decode("\#(image.base64EncodedString())"))"#

        let (result, summary) = try TypstDocumentImporter.importSource(
            source, store: temp.store, syntax: Fixtures.syntax
        )

        let ref = try #require(summary.assets.first)
        #expect(try temp.store.data(for: ref) == image)
        #expect(result == #"#image("\#(ref.path)")"#)
        // Der Quelltext ist von ~1,3 MB auf wenige Dutzend Bytes geschrumpft.
        #expect(result.utf8.count < 100)
    }

    @Test("Umgebrochenes Base64 wird erkannt")
    func handlesWrappedBase64() throws {
        let temp = try TemporaryDirectory()
        let wrapped = Fixtures.onePixelPNGBase64
            .enumerated()
            .map { $0.offset > 0 && $0.offset % 40 == 0 ? "\n\($0.element)" : "\($0.element)" }
            .joined()
        let source = #"#image(base64.decode("\#(wrapped)"))"#

        let (_, summary) = try TypstDocumentImporter.importSource(
            source, store: temp.store, syntax: Fixtures.syntax
        )

        let ref = try #require(summary.assets.first)
        #expect(try temp.store.data(for: ref) == Fixtures.onePixelPNG)
    }

    // MARK: Dateien

    @Test("Import an Ort und Stelle mit Backup")
    func importsFileInPlace() throws {
        let temp = try TemporaryDirectory()
        let documentURL = temp.url.appendingPathComponent("doc.typ")
        let backupDirectory = temp.url.appendingPathComponent("backup", isDirectory: true)

        let source = #"#image(base64.decode("\#(Fixtures.onePixelPNGBase64)"))"#
        try source.write(to: documentURL, atomically: true, encoding: .utf8)

        let summary = try TypstDocumentImporter.importFileInPlace(
            at: documentURL,
            store: temp.store,
            syntax: Fixtures.syntax,
            backupDirectory: backupDirectory
        )

        let ref = try #require(summary.assets.first)
        let rewritten = try String(contentsOf: documentURL, encoding: .utf8)
        let backup = try String(contentsOf: backupDirectory.appendingPathComponent("doc.typ"), encoding: .utf8)

        #expect(rewritten == #"#image("\#(ref.path)")"#)
        #expect(backup == source)
    }

    @Test("Unveraendertes Dokument wird nicht neu geschrieben")
    func skipsUnchangedFile() throws {
        let temp = try TemporaryDirectory()
        let documentURL = temp.url.appendingPathComponent("plain.typ")
        let source = "= Nur Text\n"
        try source.write(to: documentURL, atomically: true, encoding: .utf8)

        let summary = try TypstDocumentImporter.importFileInPlace(
            at: documentURL, store: temp.store, syntax: Fixtures.syntax
        )

        #expect(!summary.didChange)
        #expect(try String(contentsOf: documentURL, encoding: .utf8) == source)
    }

    @Test("Ein Fehler laesst das Original unangetastet")
    func failureLeavesOriginalIntact() throws {
        let temp = try TemporaryDirectory()
        let documentURL = temp.url.appendingPathComponent("broken.typ")
        // decode-Aufruf ohne schliessende Klammer.
        let source = #"#image(base64.decode("\#(Fixtures.onePixelPNGBase64)" , width: 1cm)"#
        try source.write(to: documentURL, atomically: true, encoding: .utf8)

        #expect(throws: (any Error).self) {
            try TypstDocumentImporter.importFileInPlace(
                at: documentURL, store: temp.store, syntax: Fixtures.syntax
            )
        }
        #expect(try String(contentsOf: documentURL, encoding: .utf8) == source)
    }
}
