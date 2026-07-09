//
//  RoundTripTests.swift
//  TypstAssetKitTests
//
//  Die Garantie, auf der die ganze Umstellung beruht.
//
//  Der Export erzeugt eine *kanonische* Inline-Form. Ein Bestandsdokument in
//  Form A („#let x = <base64>“ + „base64.decode(x)“ an der Verwendung) kommt
//  deshalb als „#let x = base64.decode(<base64>)“ zurueck — semantisch
//  identisch, aber normalisiert. Ab dann gilt in beide Richtungen exakt:
//
//      import(export(d)) == d      fuer jedes importierte Dokument d
//      export(import(c)) == c      fuer jedes kanonische Dokument c
//
//  Damit bleibt „Quelltext kopieren, extern bearbeiten, zurueckpasten“
//  verlustfrei — und die Migration ist nachweisbar inhaltserhaltend,
//  nicht nur plausibel: der Bild-Hash ueberlebt die Runde.
//

import Foundation
import Testing

@testable import TypstAssetKit

@Suite("Round-Trip")
struct RoundTripTests {

    /// Bestandsdokument in Form A, so wie es heute in der App liegt.
    private func documentFormA() -> String {
        """
        \(Fixtures.importLine)

        #set page(width: 10cm, height: auto)

        #let logo = "\(Fixtures.onePixelPNGBase64)"

        = Titel

        #figure(image(base64.decode(logo), width: 3cm), caption: [Das Logo])
        """
    }

    /// Bestandsdokument in Form B — zugleich schon die kanonische Form.
    private func documentFormB() -> String {
        """
        \(Fixtures.importLine)

        #image(base64.decode("\(Fixtures.onePixelPNGBase64)"), width: 3cm)
        """
    }

    @Test("Form A wird beim Export normalisiert, nicht verfaelscht")
    func roundTripFormA() throws {
        let temp = try TemporaryDirectory()

        let (imported, _) = try TypstDocumentImporter.importSource(
            documentFormA(), store: temp.store, syntax: Fixtures.syntax
        )
        let exported = try TypstDocumentExporter.exportToString(
            source: imported, store: temp.store, syntax: Fixtures.syntax
        )

        #expect(exported == """
        \(Fixtures.importLine)

        #set page(width: 10cm, height: auto)

        #let logo = base64.decode("\(Fixtures.onePixelPNGBase64)")

        = Titel

        #figure(image(logo, width: 3cm), caption: [Das Logo])
        """)
    }

    @Test("Form B: Export macht den Import exakt rueckgaengig")
    func roundTripFormB() throws {
        let temp = try TemporaryDirectory()
        let original = documentFormB()

        let (imported, _) = try TypstDocumentImporter.importSource(
            original, store: temp.store, syntax: Fixtures.syntax
        )
        let exported = try TypstDocumentExporter.exportToString(
            source: imported, store: temp.store, syntax: Fixtures.syntax
        )

        #expect(exported == original)
    }

    @Test("Kanonische Form ist ein Fixpunkt: import(export(d)) == d")
    func importOfExportIsIdentity() throws {
        let temp = try TemporaryDirectory()

        let (imported, _) = try TypstDocumentImporter.importSource(
            documentFormA(), store: temp.store, syntax: Fixtures.syntax
        )
        let exported = try TypstDocumentExporter.exportToString(
            source: imported, store: temp.store, syntax: Fixtures.syntax
        )
        let (reimported, _) = try TypstDocumentImporter.importSource(
            exported, store: temp.store, syntax: Fixtures.syntax
        )

        #expect(reimported == imported)
    }

    @Test("Der Zyklus ist stabil, nicht nur einmal korrekt")
    func cycleIsStable() throws {
        let temp = try TemporaryDirectory()

        let (importedOnce, firstSummary) = try TypstDocumentImporter.importSource(
            documentFormA(), store: temp.store, syntax: Fixtures.syntax
        )
        let exportedOnce = try TypstDocumentExporter.exportToString(
            source: importedOnce, store: temp.store, syntax: Fixtures.syntax
        )
        let (importedTwice, secondSummary) = try TypstDocumentImporter.importSource(
            exportedOnce, store: temp.store, syntax: Fixtures.syntax
        )
        let exportedTwice = try TypstDocumentExporter.exportToString(
            source: importedTwice, store: temp.store, syntax: Fixtures.syntax
        )

        #expect(importedTwice == importedOnce)
        #expect(exportedTwice == exportedOnce)
        #expect(secondSummary.assets == firstSummary.assets)
        #expect(temp.fileCount(in: "img") == 1)
    }

    @Test("Der Hash ueberlebt die Runde — Beweis der Inhaltsgleichheit")
    func hashSurvivesRoundTrip() throws {
        let temp = try TemporaryDirectory()
        let image = Fixtures.png(byteCount: 250_000)
        // Mit Import-Zeile, damit der Export sie nicht ergaenzen muss und
        // `reimported` textlich mit `imported` vergleichbar bleibt.
        let original = """
        \(Fixtures.importLine)
        #image(base64.decode("\(image.base64EncodedString())"))
        """

        let (imported, firstSummary) = try TypstDocumentImporter.importSource(
            original, store: temp.store, syntax: Fixtures.syntax
        )
        let exported = try TypstDocumentExporter.exportToString(
            source: imported, store: temp.store, syntax: Fixtures.syntax
        )

        // Zweiter Store, damit der Hash wirklich aus den exportierten Bytes stammt
        // und nicht aus dem schon vorhandenen Asset.
        let freshTemp = try TemporaryDirectory()
        let (reimported, secondSummary) = try TypstDocumentImporter.importSource(
            exported, store: freshTemp.store, syntax: Fixtures.syntax
        )

        let ref = try #require(secondSummary.assets.first)
        #expect(secondSummary.assets == firstSummary.assets)
        #expect(reimported == imported)
        #expect(try freshTemp.store.data(for: ref) == image)
    }

    @Test("Deduplizierung ueber mehrere Dokumente hinweg")
    func deduplicatesAcrossDocuments() throws {
        let temp = try TemporaryDirectory()
        let store = temp.store

        let logo = Fixtures.onePixelPNGBase64
        let documents = (1...5).map { index in
            """
            = Dokument \(index)
            #image(base64.decode("\(logo)"))
            """
        }

        var referenced: Set<TypstAssetRef> = []
        for document in documents {
            let (_, summary) = try TypstDocumentImporter.importSource(
                document, store: store, syntax: Fixtures.syntax
            )
            referenced.formUnion(summary.assets)
        }

        #expect(referenced.count == 1)
        #expect(temp.fileCount(in: "img") == 1)
    }

    @Test("Garbage Collection nach dem Loeschen eines Dokuments")
    func garbageCollectionAfterDeletion() throws {
        let temp = try TemporaryDirectory()
        let store = temp.store

        let (keptSource, keptSummary) = try TypstDocumentImporter.importSource(
            #"#image(base64.decode("\#(Fixtures.onePixelPNGBase64)"))"#,
            store: store, syntax: Fixtures.syntax
        )
        let (_, deletedSummary) = try TypstDocumentImporter.importSource(
            #"#image(base64.decode("\#(Fixtures.jpeg(byteCount: 300).base64EncodedString())"))"#,
            store: store, syntax: Fixtures.syntax
        )

        #expect(temp.fileCount(in: "img") == 2)

        // Nur noch das erste Dokument existiert.
        let stillReferenced = TypstDocumentExporter.assetReferences(in: keptSource)
        let deleted = try store.collectGarbage(referenced: stillReferenced)

        #expect(deleted == deletedSummary.assets)
        #expect(temp.fileCount(in: "img") == 1)
        #expect(try store.allAssets() == Set(keptSummary.assets))
    }
}
