//
//  TypstImageResolver.swift
//  TypstCompilerKit
//
//  Erkennt Bilder im Typst-Quelltext und lädt sie:
//  - Web-Bilder (http/https): Asynchroner Download + Quelltext-Rewriting
//  - Lokale Bilder (img/...): Laden aus einem konfigurierbaren iCloud-Container,
//    Fallback auf lokalen Cache
//
//  Resultat: modifizierter Quelltext + Liste von ImageFile für den Compiler.
//

import Foundation
import TypstAssetKit

// MARK: - Konfiguration

/// Konfiguration fuer die Aufloesung lokaler Bilder.
/// Ohne `ubiquityContainerIdentifier` werden nur Web-Bilder und der lokale Cache genutzt.
public nonisolated struct TypstImageResolverConfiguration: Sendable {
    /// iCloud-Container, aus dessen Documents/-Verzeichnis lokale Bilder geladen werden
    /// (z.B. "iCloud.dk.materialOrganizer"). nil = kein iCloud-Zugriff.
    public var ubiquityContainerIdentifier: String?

    /// Pfad-Praefix, das lokale Bilder im Quelltext markiert (Standard: "img/").
    public var localImagePrefix: String

    /// Name des Cache-Verzeichnisses unter Application Support.
    public var cacheDirectoryName: String

    public init(
        ubiquityContainerIdentifier: String? = nil,
        localImagePrefix: String = "img/",
        cacheDirectoryName: String = "TypstImageCache"
    ) {
        self.ubiquityContainerIdentifier = ubiquityContainerIdentifier
        self.localImagePrefix = localImagePrefix
        self.cacheDirectoryName = cacheDirectoryName
    }
}

// MARK: - Result-Typ

/// Ergebnis der Bildauflösung: ggf. umgeschriebener Quelltext + geladene Bilddateien.
public nonisolated struct TypstImageResolutionResult: Sendable {
    public let resolvedSource: String
    public let imageFiles: [ImageFile]

    public init(resolvedSource: String, imageFiles: [ImageFile]) {
        self.resolvedSource = resolvedSource
        self.imageFiles = imageFiles
    }
}

// MARK: - TypstImageResolver

/// Service, der alle `image(...)` Aufrufe im Typst-Quelltext analysiert und
/// die Bilddaten für den Compiler vorbereitet.
public actor TypstImageResolver {

    // MARK: - Öffentliche API

    /// Analysiert den Quelltext und löst alle enthaltenen Bildpfade auf.
    /// - Parameters:
    ///   - source: Typst-Quelltext mit potentiellen image(...)-Aufrufen
    ///   - configuration: Konfiguration fuer lokale Bildquellen
    /// - Returns: Aufgelöster Quelltext + Bilddateien für den Compiler
    public nonisolated static func resolve(
        source: String,
        configuration: TypstImageResolverConfiguration = TypstImageResolverConfiguration()
    ) async -> TypstImageResolutionResult {
        let refs = extractImageRefs(from: source)
        guard !refs.isEmpty else {
            return TypstImageResolutionResult(resolvedSource: source, imageFiles: [])
        }

        var rewrittenSource = source
        var imageFiles: [ImageFile] = []

        await withTaskGroup(of: (original: String, replacement: String?, imageFile: ImageFile?)?.self) { group in
            for ref in refs {
                group.addTask {
                    await Self.processRef(ref, configuration: configuration)
                }
            }

            for await result in group {
                guard let (original, replacement, imageFile) = result else { continue }
                if let imageFile { imageFiles.append(imageFile) }
                if let replacement {
                    rewrittenSource = rewrittenSource.replacingOccurrences(of: original, with: replacement)
                }
            }
        }

        return TypstImageResolutionResult(resolvedSource: rewrittenSource, imageFiles: imageFiles)
    }

    // MARK: - Verzeichnisse

    private static func iCloudDocumentsURL(for configuration: TypstImageResolverConfiguration) -> URL? {
        guard let containerID = configuration.ubiquityContainerIdentifier else { return nil }
        return FileManager.default
            .url(forUbiquityContainerIdentifier: containerID)?
            .appendingPathComponent("Documents")
    }

    private static func localCacheDir(for configuration: TypstImageResolverConfiguration) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(configuration.cacheDirectoryName)
    }

    // MARK: - Bildpfade extrahieren

    /// Erkennt Pfade sowohl direkt in `image("…")` als auch über eine
    /// `#let`-Zuweisung. Letzteres ist die Form, die `TypstDocumentImporter`
    /// erzeugt — ohne sie bekäme der Compiler für importierte Dokumente
    /// kein `ImageFile` und meldete „file not found“.
    ///
    /// Die Extraktion liegt in `TypstAssetKit`, weil sie reine
    /// Textverarbeitung ist und dort ohne die Rust-Binary getestet werden kann.
    private static func extractImageRefs(from source: String) -> [String] {
        TypstImageReferenceScanner.references(in: source)
    }

    // MARK: - Einzelne Referenz verarbeiten

    /// Verarbeitet einen einzelnen Bildpfad.
    /// - Returns: Tuple aus (originalPath, replacementPath?, imageFile?)
    private static func processRef(
        _ ref: String,
        configuration: TypstImageResolverConfiguration
    ) async -> (String, String?, ImageFile?)? {
        if ref.hasPrefix("http://") || ref.hasPrefix("https://") {
            return await processWebRef(ref)
        } else if ref.hasPrefix(configuration.localImagePrefix) {
            return processLocalRef(ref, configuration: configuration)
        }
        // Andere Pfade (z.B. Package-relative) werden ignoriert
        return nil
    }

    // MARK: - Web-Bilder

    /// Lädt ein Web-Bild asynchron und ersetzt den URL-Pfad durch einen virtuellen Pfad.
    /// Aus `image("https://example.com/foto.png")` wird `image("__web__/foto.png")`.
    private static func processWebRef(_ urlString: String) async -> (String, String?, ImageFile?)? {
        guard let url = URL(string: urlString) else { return nil }

        // Virtuellen Pfad aus dem letzten URL-Pfadbestandteil ableiten
        let filename = url.lastPathComponent.isEmpty ? "image_\(abs(urlString.hashValue)).bin" : url.lastPathComponent
        let virtualPath = "__web__/\(filename)"

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode),
                  !data.isEmpty else {
                print("[TypstImageResolver] Fehler beim Laden von \(urlString): Ungültige Antwort")
                return nil
            }
            let imageFile = ImageFile(path: virtualPath, content: data)
            // Quelltext umschreiben: URL → virtueller Pfad
            let original = urlString
            let replacement = virtualPath
            return (original, replacement, imageFile)
        } catch {
            print("[TypstImageResolver] Fehler beim Laden von \(urlString): \(error)")
            return nil
        }
    }

    // MARK: - Lokale Bilder

    /// Lädt ein lokales Bild aus dem konfigurierten iCloud-Container (Documents/...).
    /// Bei nicht verfuegbarer iCloud wird auf den lokalen Cache zurueckgegriffen.
    /// Der Pfad im Quelltext bleibt unverändert.
    private static func processLocalRef(
        _ path: String,
        configuration: TypstImageResolverConfiguration
    ) -> (String, String?, ImageFile?)? {
        if let baseURL = iCloudDocumentsURL(for: configuration) {
            let fileURL = baseURL.appendingPathComponent(path)
            try? FileManager.default.startDownloadingUbiquitousItem(at: fileURL)

            if let data = try? Data(contentsOf: fileURL), !data.isEmpty {
                cacheLocalImage(path: path, data: data, configuration: configuration)
                let imageFile = ImageFile(path: path, content: data)
                return (path, nil, imageFile)
            }
        }

        if let data = loadCachedImage(path: path, configuration: configuration) {
            let imageFile = ImageFile(path: path, content: data)
            return (path, nil, imageFile)
        }

        print("[TypstImageResolver] Bild weder in iCloud noch im Cache gefunden: \(path)")
        return nil
    }

    // MARK: - Bild-Cache

    private static func cacheLocalImage(
        path: String,
        data: Data,
        configuration: TypstImageResolverConfiguration
    ) {
        let cacheURL = localCacheDir(for: configuration).appendingPathComponent(path)
        let parentDir = cacheURL.deletingLastPathComponent()
        let fm = FileManager.default
        if !fm.fileExists(atPath: parentDir.path) {
            try? fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
        }
        try? data.write(to: cacheURL)
    }

    private static func loadCachedImage(
        path: String,
        configuration: TypstImageResolverConfiguration
    ) -> Data? {
        let cacheURL = localCacheDir(for: configuration).appendingPathComponent(path)
        guard let data = try? Data(contentsOf: cacheURL), !data.isEmpty else { return nil }
        return data
    }
}
