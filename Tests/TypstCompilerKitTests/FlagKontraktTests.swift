//
//  FlagKontraktTests.swift
//  TypstCompilerKitTests
//
//  B4-Tests für den Flag-Kontrakt v1:
//  1. Input-Flags erreichen sys.inputs
//  2. Extraktion: Seiten 0-basiert, Positionen plausibel, Payload JSON-getreu
//  3. Gebündeltes mo-tools-Paket kompiliert und meldet
//  4. Additivitäts-Nachweis: alte Konformer bleiben gültig (Extension-Default)
//

import Foundation
import PDFKit
import Testing

@testable import TypstCompilerKit

// MARK: - Hilfen

/// Extrahiert den Text eines PDFs (alle Seiten).
private func pdfText(_ data: Data) -> String {
    guard let doc = PDFDocument(data: data) else { return "" }
    return (0..<doc.pageCount)
        .compactMap { doc.page(at: $0)?.string }
        .joined(separator: "\n")
}

// MARK: - Tests

@MainActor
struct FlagKontraktTests {

    // B4.1: inputs erreichen sys.inputs
    @Test func inputsErreichenSysInputs() async throws {
        let compiler = NativeTypstCompiler()
        let quelle = #"Wert: #sys.inputs.at("x", default: "leer")"#

        let ohne = try await compiler.kompiliereMitFlags(
            source: quelle, packageFiles: [], imageFiles: [], inputs: [:]
        )
        #expect(pdfText(ohne.pdf).contains("leer"))
        #expect(ohne.ausgaben.isEmpty)

        let mit = try await compiler.kompiliereMitFlags(
            source: quelle, packageFiles: [], imageFiles: [], inputs: ["x": "hallo"]
        )
        #expect(pdfText(mit.pdf).contains("hallo"))
        #expect(!pdfText(mit.pdf).contains("leer"))
    }

    // B4.2: Extraktion — vier Seitenecken + Seite 2, Payload JSON-getreu
    @Test func extraktionLiefertSeitenPositionenUndPayloads() async throws {
        let compiler = NativeTypstCompiler()
        // A4: 595.28 x 841.89 pt. Marker via place in den vier Ecken,
        // dazu eine Meldung mit allen Payload-Typen und eine auf Seite 2.
        let quelle = """
        #set page(paper: "a4", margin: 0pt)
        #place(top + left)[#metadata((typ: "ecke", daten: (pos: "ol")))<mo-element>]
        #place(top + right)[#metadata((typ: "ecke", daten: (pos: "or")))<mo-element>]
        #place(bottom + left)[#metadata((typ: "ecke", daten: (pos: "ul")))<mo-element>]
        #place(bottom + right)[#metadata((typ: "ecke", daten: (pos: "ur")))<mo-element>]
        #metadata((typ: "typen", daten: (s: "text", i: 7, f: 1.5, b: true, a: (1, 2), n: none)))<mo-element>
        #pagebreak()
        #metadata((typ: "zweite", daten: (:)))<mo-element>
        Inhalt
        """

        let ergebnis = try await compiler.kompiliereMitFlags(
            source: quelle, packageFiles: [], imageFiles: [], inputs: [:]
        )
        let ausgaben = ergebnis.ausgaben
        #expect(ausgaben.count == 6)

        // Seitenindizes 0-basiert
        let ecken = ausgaben.filter { $0.typ == "ecke" }
        #expect(ecken.count == 4)
        #expect(ecken.allSatisfy { $0.seite == 0 })
        let zweite = try #require(ausgaben.first { $0.typ == "zweite" })
        #expect(zweite.seite == 1)

        // Positionen plausibel (A4, Toleranz 40 pt; Ursprung oben links)
        let breite = 595.28, hoehe = 841.89, toleranz = 40.0
        func ecke(_ pos: String) throws -> MoAusgabe {
            try #require(ecken.first { $0.daten["pos"]?.textWert == pos })
        }
        let ol = try ecke("ol"), or = try ecke("or")
        let ul = try ecke("ul"), ur = try ecke("ur")
        #expect(ol.xPt < toleranz && ol.yPt < toleranz)
        #expect(abs(or.xPt - breite) < toleranz && or.yPt < toleranz)
        #expect(ul.xPt < toleranz && abs(ul.yPt - hoehe) < toleranz)
        #expect(abs(ur.xPt - breite) < toleranz && abs(ur.yPt - hoehe) < toleranz)

        // Payload JSON-getreu
        let typen = try #require(ausgaben.first { $0.typ == "typen" })
        #expect(typen.daten["s"] == .text("text"))
        #expect(typen.daten["i"] == .ganzzahl(7))
        #expect(typen.daten["f"] == .zahl(1.5))
        #expect(typen.daten["b"] == .bool(true))
        #expect(typen.daten["a"] == .liste([.ganzzahl(1), .ganzzahl(2)]))
        #expect(typen.daten["n"] == MoJSONWert.null)
    }

    // B4.3 ist mit dem Paket in die App gewandert
    // (MaterialOrganizerTests/Features/Vorbereitung/MoToolsTests.swift):
    // welche Makros es gibt und was sie melden, ist App-Semantik. Hier bleibt
    // der Mechanismus — Label-Extraktion, Payload-Typen, Additivitaet.

    // B4.4: Additivitäts-Nachweis — Konformer mit NUR den alten Requirements
    // kompiliert und liefert über den Extension-Default (pdf, []).
    @Test func alteKonformerNutzenExtensionDefault() async throws {
        /// Implementiert ausschließlich die bestehenden Protokoll-Requirements.
        final class NurAlteAPI: NativeTypstCompilerProtocol, @unchecked Sendable {
            func compileToPDF(source: String, packageFiles: [PackageFile], imageFiles: [ImageFile]) async throws -> Data {
                Data("stub-pdf".utf8)
            }
            func compileToSVG(source: String, packageFiles: [PackageFile], imageFiles: [ImageFile]) async throws -> [String] {
                []
            }
        }

        let mock: any NativeTypstCompilerProtocol = NurAlteAPI()
        let ergebnis = try await mock.kompiliereMitFlags(
            source: "egal", packageFiles: [], imageFiles: [], inputs: ["x": "y"]
        )
        #expect(ergebnis.pdf == Data("stub-pdf".utf8))
        #expect(ergebnis.ausgaben.isEmpty)
    }

    // Existential Dispatch: über `any NativeTypstCompilerProtocol` muss der
    // echte FFI-Pfad erreicht werden (Brücke im Extension-Default).
    @Test func existentialErreichtFFIPfad() async throws {
        let compiler: any NativeTypstCompilerProtocol = NativeTypstCompiler()
        let quelle = #"#metadata((typ: "ping", daten: (:)))<mo-element>Hallo"#
        let ergebnis = try await compiler.kompiliereMitFlags(
            source: quelle, packageFiles: [], imageFiles: [], inputs: [:]
        )
        #expect(ergebnis.ausgaben.map(\.typ) == ["ping"])
    }
}
