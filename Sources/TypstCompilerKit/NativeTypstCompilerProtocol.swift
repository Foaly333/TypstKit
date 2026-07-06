//
//  NativeTypstCompilerProtocol.swift
//  TypstCompilerKit
//
//  Protokoll und Fehlertypen fuer den nativen Typst-Compiler.
//  Ermoeglicht Mocking in Tests und Entkopplung vom FFI-Layer.
//

import Foundation
import SwiftUI

// MARK: - Preview-Stub (kein FFI-Zugriff)

/// Leichtgewichtiger Compiler-Stub fuer SwiftUI-Previews und Tests.
/// Gibt leere Ergebnisse zurueck, da die Rust-FFI-Binary im Preview-Prozess nicht verfuegbar ist.
public final class PreviewTypstCompiler: NativeTypstCompilerProtocol, @unchecked Sendable {
    public init() {}
    public func compileToPDF(source: String, packageFiles: [PackageFile], imageFiles: [ImageFile]) async throws -> Data { Data() }
    public func compileToSVG(source: String, packageFiles: [PackageFile], imageFiles: [ImageFile]) async throws -> [String] { [] }
}

// MARK: - Environment-Key fuer geteilte Compiler-Instanz

extension EnvironmentValues {
    @Entry public var typstCompiler: any NativeTypstCompilerProtocol = {
        if ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" {
            return PreviewTypstCompiler()
        }
        return NativeTypstCompiler()
    }()
}

// MARK: - Diagnose-Typen

/// Einzelne Compiler-Diagnose (Fehler oder Warnung).
public nonisolated struct NativeTypstDiagnostic: Sendable, Identifiable {
    public let id = UUID()
    /// "error" oder "warning"
    public let severity: String
    /// Fehlermeldung
    public let message: String
    /// Zeilennummer (1-basiert, 0 wenn unbekannt)
    public let line: UInt32
    /// Spaltennummer (1-basiert, 0 wenn unbekannt)
    public let column: UInt32

    public var isError: Bool { severity == "error" }

    public init(severity: String, message: String, line: UInt32, column: UInt32) {
        self.severity = severity
        self.message = message
        self.line = line
        self.column = column
    }
}

/// Fehler bei der Kompilierung mit detaillierten Diagnosen.
public nonisolated struct NativeTypstCompilationError: Error, Sendable {
    public let diagnostics: [NativeTypstDiagnostic]
    public let summary: String

    public init(diagnostics: [NativeTypstDiagnostic], summary: String) {
        self.diagnostics = diagnostics
        self.summary = summary
    }
}

// MARK: - Compiler-Protokoll

/// Protokoll fuer den nativen Typst-Compiler-Service.
/// Ermoeglicht Constructor Injection und Testbarkeit.
public protocol NativeTypstCompilerProtocol: Sendable {
    /// Kompiliert Typst-Quelltext zu PDF-Bytes.
    /// - Parameters:
    ///   - source: Vollstaendiger Typst-Quelltext (ggf. bereits umgeschrieben fuer Web-Bilder)
    ///   - packageFiles: Entpackte Package-Dateien fuer die Aufloesung von Imports
    ///   - imageFiles: Virtuelle Bilddateien (Web-Downloads + lokale Bilddateien)
    /// - Returns: PDF als Data
    func compileToPDF(source: String, packageFiles: [PackageFile], imageFiles: [ImageFile]) async throws -> Data

    /// Kompiliert Typst-Quelltext zu SVG-Strings (einer pro Seite).
    /// - Parameters:
    ///   - source: Vollstaendiger Typst-Quelltext (ggf. bereits umgeschrieben fuer Web-Bilder)
    ///   - packageFiles: Entpackte Package-Dateien fuer die Aufloesung von Imports
    ///   - imageFiles: Virtuelle Bilddateien (Web-Downloads + lokale Bilddateien)
    /// - Returns: Array von SVG-Strings (einer pro Seite)
    func compileToSVG(source: String, packageFiles: [PackageFile], imageFiles: [ImageFile]) async throws -> [String]
}
