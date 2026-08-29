//
//  TypstPackageManagerTests.swift
//  TypstCompilerKitTests
//
//  Der Package-Manager darf nur Registry-Pakete (@preview) herunterladen.
//  Lokale Pakete (@local/…, z. B. das app-eigene mo-tools) liefert die App
//  selbst über `additionalPackageFiles`; ein Download-Versuch endet dort mit
//  HTTP 404.
//
//  Das Testpaket unten steht stellvertretend fuer solche App-Pakete — TypstKit
//  buendelt seit August 2026 selbst keines mehr.
//

import Foundation
import Testing

@testable import TypstCompilerKit

/// Minimales lokales Paket als Testvorlage: gleiche Form wie die Pakete, die
/// eine App ueber `additionalPackageFiles` beisteuert.
private enum TestPaket {
    static let namespace = "local"
    static let name = "mo-pruef"
    static let version = "0.1.0"
    static let importZeile = "#import \"@local/mo-pruef:0.1.0\": *"

    static let files: [PackageFile] = [
        datei("typst.toml", """
        [package]
        name = "mo-pruef"
        version = "0.1.0"
        entrypoint = "lib.typ"
        """),
        datei("lib.typ", """
        #let pruef-melde(typ, daten: (:)) = [#metadata((typ: typ, daten: daten))<mo-element>]
        """),
    ]

    private static func datei(_ pfad: String, _ inhalt: String) -> PackageFile {
        PackageFile(
            namespace: namespace,
            name: name,
            version: version,
            path: pfad,
            content: Data(inhalt.utf8)
        )
    }
}

@MainActor
struct TypstPackageManagerTests {

    @Test("scanImports erfasst alle Namespaces")
    func scanImports_erfasstAlleNamespaces() {
        let quelle = """
        #import "@preview/cades:0.3.1": qr-code
        #import "@local/mo-tools:0.1.0": *
        """

        let specs = TypstPackageManager.scanImports(in: quelle)

        #expect(specs.count == 2)
        #expect(specs.contains(TypstPackageSpec(namespace: "preview", name: "cades", version: "0.3.1")))
        #expect(specs.contains(TypstPackageSpec(namespace: "local", name: "mo-tools", version: "0.1.0")))
    }

    @Test("Lokale Pakete werden nicht heruntergeladen")
    func resolvePackages_ignoriertLokalePakete() async throws {
        let manager = TypstPackageManager()

        // Ohne den Namespace-Filter liefe das in einen HTTP-404 und würfe.
        let dateien = try await manager.resolvePackages(for: TestPaket.importZeile)

        #expect(dateien.isEmpty)
    }

    @Test("Gleichnamige Dateien verschiedener Pakete bleiben erhalten")
    func zusammenfuehren_behaeltGleichnamigeDateienAndererPakete() {
        // Jedes Paket bringt typst.toml und lib.typ mit — eine Deduplizierung
        // ueber den Pfad wuerde das lokale Paket verschlucken.
        let ausRegistry = [
            PackageFile(namespace: "preview", name: "cades", version: "0.3.1", path: "typst.toml", content: Data()),
            PackageFile(namespace: "preview", name: "cades", version: "0.3.1", path: "lib.typ", content: Data()),
        ]

        let zusammen = NativeTypstController.zusammenfuehren(ausRegistry, mit: TestPaket.files)

        let lokaleDateien = zusammen.filter { $0.name == TestPaket.name }
        #expect(lokaleDateien.contains { $0.path == "typst.toml" })
        #expect(lokaleDateien.contains { $0.path == "lib.typ" })
        #expect(lokaleDateien.count == TestPaket.files.count)
    }

    @Test("Identische Dateien werden nicht doppelt angehaengt")
    func zusammenfuehren_dedupliziertEchteDubletten() {
        let dateien = TestPaket.files

        let zusammen = NativeTypstController.zusammenfuehren(dateien, mit: dateien)

        #expect(zusammen.count == dateien.count)
    }

    @Test("Quelltext mit lokalem Paket-Import kompiliert mit mitgeliefertem Paket")
    func kompilieren_mitLokalemPaket() async throws {
        let compiler = NativeTypstCompiler()
        let quelle = """
        \(TestPaket.importZeile)
        #pruef-melde("kann", daten: (flag: "loesung"))
        Test
        """

        let (pdf, ausgaben) = try await compiler.kompiliereMitFlags(
            source: quelle,
            packageFiles: TestPaket.files,
            imageFiles: [],
            inputs: [:]
        )

        #expect(!pdf.isEmpty)
        #expect(ausgaben.contains { $0.typ == "kann" })
    }
}
