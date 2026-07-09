//
//  TypstDocumentExporterTests.swift
//  TypstAssetKitTests
//

import Foundation
import Testing

@testable import TypstAssetKit

@Suite("Dokument-Export")
struct TypstDocumentExporterTests {

    @Test("Direkter Pfad wird zum decode-Aufruf")
    func inlinesDirectPath() throws {
        let temp = try TemporaryDirectory()
        let ref = try temp.store.store(data: Fixtures.onePixelPNG)

        let exported = try TypstDocumentExporter.exportToString(
            source: #"#image("\#(ref.path)", width: 2cm)"#,
            store: temp.store,
            syntax: Fixtures.syntax
        )

        #expect(exported == """
        \(Fixtures.importLine)
        #image(base64.decode("\(Fixtures.onePixelPNGBase64)"), width: 2cm)
        """)
    }

    @Test("#let-Pfad wird zur decode-Zuweisung, Verwendungen bleiben unberuehrt")
    func inlinesLetAssignment() throws {
        let temp = try TemporaryDirectory()
        let ref = try temp.store.store(data: Fixtures.onePixelPNG)

        let source = """
        \(Fixtures.importLine)

        #let logo = "\(ref.path)"

        #image(logo)
        #box(image(logo, width: 1cm))
        """

        let exported = try TypstDocumentExporter.exportToString(
            source: source, store: temp.store, syntax: Fixtures.syntax
        )

        #expect(exported == """
        \(Fixtures.importLine)

        #let logo = base64.decode("\(Fixtures.onePixelPNGBase64)")

        #image(logo)
        #box(image(logo, width: 1cm))
        """)
    }

    @Test("Woerter im Fliesstext werden nicht angefasst")
    func leavesProseAlone() throws {
        let temp = try TemporaryDirectory()
        let ref = try temp.store.store(data: Fixtures.onePixelPNG)

        // `logo` kommt als Bezeichner *und* als gewoehnliches Wort vor.
        let source = """
        #let logo = "\(ref.path)"
        Das logo steht oben rechts.
        """

        let exported = try TypstDocumentExporter.exportToString(
            source: source, store: temp.store, syntax: Fixtures.syntax
        )

        #expect(exported.hasSuffix("Das logo steht oben rechts."))
    }

    @Test("Die Import-Zeile wird nur bei Bedarf ergaenzt")
    func addsImportLineOnlyWhenMissing() throws {
        let temp = try TemporaryDirectory()
        let ref = try temp.store.store(data: Fixtures.onePixelPNG)

        let withoutImport = try TypstDocumentExporter.exportToString(
            source: #"#image("\#(ref.path)")"#, store: temp.store, syntax: Fixtures.syntax
        )
        let withImport = try TypstDocumentExporter.exportToString(
            source: "\(Fixtures.importLine)\n#image(\"\(ref.path)\")",
            store: temp.store,
            syntax: Fixtures.syntax
        )

        #expect(withoutImport.hasPrefix(Fixtures.importLine))
        #expect(withImport.components(separatedBy: Fixtures.importLine).count == 2)
    }

    @Test("Dokumente ohne Assets bleiben unveraendert")
    func leavesAssetFreeDocumentsAlone() throws {
        let temp = try TemporaryDirectory()
        let source = """
        = Titel
        #let name = "Daniel"
        Text mit "kurzem String" und img/ohne-hash.png
        """

        let exported = try TypstDocumentExporter.exportToString(
            source: source, store: temp.store, syntax: Fixtures.syntax
        )

        #expect(exported == source)
    }

    @Test("Ein fehlendes Asset meldet sich, statt still zu verschwinden")
    func missingAssetThrows() throws {
        let temp = try TemporaryDirectory()
        let ref = TypstAssetRef(hash: String(repeating: "b", count: 32), format: .png)

        #expect(throws: TypstAssetError.missingAsset(ref.path)) {
            try TypstDocumentExporter.exportToString(
                source: #"#image("\#(ref.path)")"#, store: temp.store, syntax: Fixtures.syntax
            )
        }
    }

    @Test("Referenzen werden vollstaendig gefunden")
    func findsAllReferences() throws {
        let temp = try TemporaryDirectory()
        let png = try temp.store.store(data: Fixtures.onePixelPNG)
        let jpeg = try temp.store.store(data: Fixtures.jpeg(byteCount: 64))

        let source = """
        #let a = "\(png.path)"
        #image("\(jpeg.path)")
        #image("\(png.path)")
        #let unrelated = "img/kein-hash.png"
        """

        #expect(TypstDocumentExporter.assetReferences(in: source) == [png, jpeg])
    }

    @Test("Export in eine Datei streamt grosse Bilder")
    func exportsLargeImageToFile() throws {
        let temp = try TemporaryDirectory()
        let image = Fixtures.png(byteCount: 1_000_000)
        let ref = try temp.store.store(data: image)
        let outputURL = temp.url.appendingPathComponent("out.typ")

        let count = try TypstDocumentExporter.exportFile(
            source: #"#image("\#(ref.path)")"#,
            store: temp.store,
            to: outputURL,
            syntax: Fixtures.syntax
        )

        let exported = try String(contentsOf: outputURL, encoding: .utf8)
        #expect(count == 1)
        #expect(exported.contains(image.base64EncodedString()))
    }
}
