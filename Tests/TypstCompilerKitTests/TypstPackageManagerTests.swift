//
//  TypstPackageManagerTests.swift
//  TypstCompilerKitTests
//
//  Der Package-Manager darf nur Registry-Pakete (@preview) herunterladen.
//  Lokale Pakete (@local/…, z. B. mo-tools) liefert die App selbst über
//  `additionalPackageFiles`; ein Download-Versuch endet dort mit HTTP 404.
//

import Foundation
import Testing

@testable import TypstCompilerKit

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
        let dateien = try await manager.resolvePackages(for: MoToolsPackage.importZeile)

        #expect(dateien.isEmpty)
    }

    @Test("Quelltext mit mo-tools-Import kompiliert mit mitgeliefertem Paket")
    func kompilieren_mitLokalemPaket() async throws {
        let compiler = NativeTypstCompiler()
        let quelle = """
        \(MoToolsPackage.importZeile)
        #mo-kann("loesung")
        Test
        """

        let (pdf, ausgaben) = try await compiler.kompiliereMitFlags(
            source: quelle,
            packageFiles: MoToolsPackage.files,
            imageFiles: [],
            inputs: [:]
        )

        #expect(!pdf.isEmpty)
        #expect(ausgaben.contains { $0.typ == "kann" })
    }
}
