//
//  NativeTypstCompiler.swift
//  TypstCompilerKit
//
//  Wrapper um die nativen Rust-FFI-Funktionen.
//  Laedt Schriftarten aus einem Bundle und delegiert die Kompilierung
//  an die via UniFFI generierten Funktionen (compileToPdf/compileToSvg).
//
//  Hinweis: Die Rust-Binary bettet die Typst-Standardschriften selbst ein
//  (Libertinus Serif, New Computer Modern Math, DejaVu Sans Mono) — Bundle-
//  und Systemfonts hier ergaenzen nur zusaetzliche Schriftfamilien.
//

import CoreText
import Foundation

/// Laedt Schriftarten aus einem Bundle und ruft die Rust-kompilierten
/// Typst-Funktionen auf. Laeuft auf iOS und macOS.
public final class NativeTypstCompiler: NativeTypstCompilerProtocol, Sendable {
    /// Vorgeladene Font-Daten
    private let fontData: [Data]

    /// Erstellt einen neuen Compiler mit Fonts aus dem angegebenen Bundle-Verzeichnis.
    /// - Parameters:
    ///   - bundle: Bundle, in dem nach Fonts gesucht wird (Standard: .main)
    ///   - fontDirectoryName: Name des Verzeichnisses im Bundle (Standard: "Fonts")
    ///   - includeSystemFontFallback: Laedt bevorzugte Systemfonts via CoreText,
    ///     falls das Bundle-Verzeichnis leer ist (Standard: true)
    public init(
        bundle: Bundle = .main,
        fontDirectoryName: String = "Fonts",
        includeSystemFontFallback: Bool = true
    ) {
        var fonts: [Data] = []

        if let fontsURL = bundle.resourceURL?.appendingPathComponent(fontDirectoryName) {
            let fm = FileManager.default
            let validExtensions = Set(["ttf", "otf", "ttc"])

            if let files = try? fm.contentsOfDirectory(at: fontsURL, includingPropertiesForKeys: nil) {
                for file in files where validExtensions.contains(file.pathExtension.lowercased()) {
                    if let data = try? Data(contentsOf: file) {
                        fonts.append(data)
                    }
                }
            }
        }

        // Fallback: Systemfonts ueber CoreText laden.
        // Hartcodierte Dateipfade funktionieren nicht innerhalb der Sandbox;
        // CoreText liefert gueltige, lesbare Font-URLs auf iOS und macOS.
        if fonts.isEmpty && includeSystemFontFallback {
            fonts = Self.loadSystemFonts()
        }

        self.fontData = fonts
    }

    /// Laedt eine begrenzte Auswahl an Systemfonts ueber die CoreText-API.
    /// Es werden nur bevorzugte Fonts geladen, um den Speicherverbrauch gering zu halten.
    private static func loadSystemFonts() -> [Data] {
        // Bevorzugte Font-Familien fuer die Typst-Kompilierung.
        let preferredFamilies: [String] = [
            "Helvetica", "Helvetica Neue", "Times New Roman", "Courier New",
            "Arial", "Georgia", "Verdana", "SF Pro", "SF Pro Text", "SF Pro Display",
            "New York", "Menlo", "SF Mono"
        ]

        var fonts: [Data] = []
        var seenURLs = Set<URL>()
        let validExtensions: Set<String> = ["ttf", "otf", "ttc"]

        for family in preferredFamilies {
            let attributes = [kCTFontFamilyNameAttribute: family] as CFDictionary
            let descriptor = CTFontDescriptorCreateWithAttributes(attributes)
            let collection = CTFontCollectionCreateWithFontDescriptors([descriptor] as CFArray, nil)
            guard let descriptors = CTFontCollectionCreateMatchingFontDescriptors(collection) as? [CTFontDescriptor] else {
                continue
            }
            for desc in descriptors {
                guard let url = CTFontDescriptorCopyAttribute(desc, kCTFontURLAttribute) as? URL,
                      validExtensions.contains(url.pathExtension.lowercased()),
                      !seenURLs.contains(url) else { continue }
                seenURLs.insert(url)
                if let data = try? Data(contentsOf: url) {
                    fonts.append(data)
                }
            }
        }

        return fonts
    }

    /// Kompiliert Typst-Quelltext zu PDF auf dem Global Concurrent Executor.
    @concurrent
    public nonisolated func compileToPDF(source: String, packageFiles: [PackageFile], imageFiles: [ImageFile]) async throws -> Data {
        do {
            return try compileToPdf(source: source, fontData: fontData, packageFiles: packageFiles, imageFiles: imageFiles)
        } catch let error as TypstCompilationError {
            throw error.toNativeError()
        }
    }

    /// Kompiliert Typst-Quelltext zu SVG auf dem Global Concurrent Executor.
    @concurrent
    public nonisolated func compileToSVG(source: String, packageFiles: [PackageFile], imageFiles: [ImageFile]) async throws -> [String] {
        do {
            return try compileToSvg(source: source, fontData: fontData, packageFiles: packageFiles, imageFiles: imageFiles)
        } catch let error as TypstCompilationError {
            throw error.toNativeError()
        }
    }
}

// MARK: - Mapping von UniFFI-Typen auf Kit-Typen

private extension TypstCompilationError {
    /// Konvertiert den UniFFI-Fehlertyp in den oeffentlichen Kit-Fehlertyp.
    nonisolated func toNativeError() -> NativeTypstCompilationError {
        switch self {
        case .CompileError(let diagnostics, let summary),
             .ExportError(let diagnostics, let summary):
            return NativeTypstCompilationError(
                diagnostics: diagnostics.map { diag in
                    NativeTypstDiagnostic(
                        severity: diag.severity,
                        message: diag.message,
                        line: diag.line,
                        column: diag.column
                    )
                },
                summary: summary
            )
        }
    }
}
