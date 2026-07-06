//
//  NativeTypstController.swift
//  TypstCompilerKit
//
//  @Observable Controller fuer native Typst-Kompilierung.
//  Verwaltet den Kompilierungs-Lifecycle mit Debouncing und
//  stellt PDF/SVG-Ergebnisse fuer die View bereit.
//

import Foundation
import PDFKit

/// Ausgabeformat der Kompilierung.
public enum NativeTypstOutputFormat: Sendable {
    case pdf
    case svg
    case both
}

@Observable
public final class NativeTypstController {
    // MARK: - Oeffentlicher State

    /// Kompiliertes PDF-Dokument fuer PDFKit-Anzeige.
    public var pdfDocument: PDFDocument?

    /// Rohe PDF-Daten fuer Export/Sharing.
    public var pdfData: Data?

    /// SVG-Strings (einer pro Seite).
    public var svgPages: [String] = []

    /// Gibt an, ob gerade kompiliert wird.
    public var isCompiling = false

    /// Kompilierungsfehler und -warnungen.
    public var compilationErrors: [NativeTypstDiagnostic] = []

    /// Zusammenfassung der Fehler als lesbarer String.
    public var errorSummary: String?

    /// Ausgabeformat (PDF, SVG oder beides).
    public var outputFormat: NativeTypstOutputFormat = .pdf

    // MARK: - Private

    private let compiler: NativeTypstCompilerProtocol
    private let packageManager = TypstPackageManager()
    private let imageResolverConfiguration: TypstImageResolverConfiguration
    private let additionalPackageFiles: () -> [PackageFile]
    private let exportFileNamer: (String) -> String
    private var compileTask: Task<Void, Never>?
    private let debounceDelay: UInt64

    // MARK: - Init (Constructor Injection)

    /// Erstellt einen neuen Controller.
    /// - Parameters:
    ///   - compiler: Der zu verwendende Compiler-Service
    ///   - outputFormat: Ausgabeformat (Standard: .pdf)
    ///   - debounceDelay: Verzoegerung in Millisekunden vor der Kompilierung (Standard: 400ms)
    ///   - imageResolverConfiguration: Konfiguration fuer lokale Bildquellen (iCloud-Container etc.)
    ///   - additionalPackageFiles: Liefert zusaetzliche Package-Dateien pro Kompilierung
    ///     (z.B. lokale #import-Dateien aus einem Template-Store der App)
    ///   - exportFileNamer: Erzeugt aus einem Titel einen sicheren PDF-Dateinamen
    public init(
        compiler: NativeTypstCompilerProtocol,
        outputFormat: NativeTypstOutputFormat = .pdf,
        debounceDelay: UInt64 = 400,
        imageResolverConfiguration: TypstImageResolverConfiguration = TypstImageResolverConfiguration(),
        additionalPackageFiles: @escaping () -> [PackageFile] = { [] },
        exportFileNamer: @escaping (String) -> String = NativeTypstController.defaultFileName(for:)
    ) {
        self.compiler = compiler
        self.outputFormat = outputFormat
        self.debounceDelay = debounceDelay
        self.imageResolverConfiguration = imageResolverConfiguration
        self.additionalPackageFiles = additionalPackageFiles
        self.exportFileNamer = exportFileNamer
    }

    // MARK: - Kompilierung

    /// Plant eine debounced Kompilierung.
    /// Bricht vorherige geplante Kompilierungen ab.
    public func scheduleCompilation(source: some TypstProvidingProtocol) {
        let fullSource = source.typst
        compileTask?.cancel()
        compileTask = Task {
            try? await Task.sleep(nanoseconds: debounceDelay * 1_000_000)
            guard !Task.isCancelled else { return }
            await compile(source: fullSource)
        }
    }

    /// Stoesst eine Kompilierung sofort an (ohne Debounce).
    /// Bricht vorherige geplante Kompilierungen ab.
    public func compileNow(source: some TypstProvidingProtocol) {
        let fullSource = source.typst
        compileTask?.cancel()
        compileTask = Task {
            guard !Task.isCancelled else { return }
            await compile(source: fullSource)
        }
    }

    /// Fuehrt die Kompilierung sofort aus.
    /// - Parameter source: Der zu kompilierende Typst-Quelltext
    public func compile(source: some TypstProvidingProtocol) async {
        guard !isCompiling else { return }
        isCompiling = true
        defer { isCompiling = false }

        let fullSource = source.typst

        compilationErrors = []
        errorSummary = nil

        do {
            // Packages aus dem Quelltext erkennen und laden
            var packageFiles = try await packageManager.resolvePackages(for: fullSource)

            // Zusaetzliche Dateien der App anhaengen (z.B. lokale #import-Dateien)
            let localFiles = additionalPackageFiles()
            let existingPaths = Set(packageFiles.map { $0.path })
            packageFiles += localFiles.filter { !existingPaths.contains($0.path) }

            // Bilder auflösen: Web-URLs herunterladen, lokale Bilddateien laden
            let imageResolution = await TypstImageResolver.resolve(
                source: fullSource,
                configuration: imageResolverConfiguration
            )
            let resolvedSource = imageResolution.resolvedSource
            let imageFiles = imageResolution.imageFiles

            switch outputFormat {
            case .pdf:
                let data = try await compiler.compileToPDF(source: resolvedSource, packageFiles: packageFiles, imageFiles: imageFiles)
                pdfData = data
                pdfDocument = PDFDocument(data: data)

            case .svg:
                svgPages = try await compiler.compileToSVG(source: resolvedSource, packageFiles: packageFiles, imageFiles: imageFiles)

            case .both:
                async let pdfResult = compiler.compileToPDF(source: resolvedSource, packageFiles: packageFiles, imageFiles: imageFiles)
                async let svgResult = compiler.compileToSVG(source: resolvedSource, packageFiles: packageFiles, imageFiles: imageFiles)
                let (pdf, svg) = try await (pdfResult, svgResult)
                pdfData = pdf
                pdfDocument = PDFDocument(data: pdf)
                svgPages = svg
            }
        } catch let error as NativeTypstCompilationError {
            compilationErrors = error.diagnostics
            errorSummary = error.summary
        } catch {
            errorSummary = error.localizedDescription
        }
    }

    /// Bricht die aktuelle Kompilierung ab.
    public func cancelCompilation() {
        compileTask?.cancel()
    }

    // MARK: - Export

    /// Erstellt eine temporaere PDF-Datei fuer den Export.
    /// - Parameter title: Optionaler Titel fuer den Dateinamen (wird bereinigt)
    /// - Returns: URL der temporaeren PDF-Datei, nil bei Fehler
    public func createTemporaryPDFFile(title: String = "") -> URL? {
        guard let data = pdfData else { return nil }
        let fileName = exportFileNamer(title)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(fileName)
        do {
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }

    /// Standard-Dateinamens-Bereinigung: entfernt ungueltige Zeichen,
    /// ersetzt Leerzeichen und stellt die .pdf-Endung sicher.
    public nonisolated static func defaultFileName(for title: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        var cleaned = title
            .components(separatedBy: invalid)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "-")

        if cleaned.isEmpty {
            cleaned = "Typst-Dokument"
        }
        return cleaned.hasSuffix(".pdf") ? cleaned : cleaned + ".pdf"
    }
}
