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
//  Zwei Grundregeln, beide teuer erkauft:
//
//  1. Umgeschrieben wird ausschließlich das Quelltext-Literal, aus dem ein
//     Kandidat stammt — über seine Range, nie über Stringgleichheit. Ein
//     globales Ersetzen kennt den Unterschied zwischen Code und Fließtext nicht
//     und zerstört Links, die dieselbe Zeichenfolge enthalten.
//  2. Eine Web-Ressource wird nur übernommen, wenn die Antwort tatsächlich ein
//     Bild ist. Alles andere wird still verworfen: `#let url = "https://…"` ist
//     ein legitimes Literal und darf keine Diagnostik erzeugen.
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

    /// Lader fuer Web-Ressourcen. Injizierbar, damit die Aufloesung ohne Netz
    /// testbar ist; im Betrieb `URLSession.shared`.
    public var loadWebResource: @Sendable (URL) async throws -> (Data, URLResponse)

    public init(
        ubiquityContainerIdentifier: String? = nil,
        localImagePrefix: String = "img/",
        cacheDirectoryName: String = "TypstImageCache",
        loadWebResource: @escaping @Sendable (URL) async throws -> (Data, URLResponse) = {
            try await URLSession.shared.data(from: $0)
        }
    ) {
        self.ubiquityContainerIdentifier = ubiquityContainerIdentifier
        self.localImagePrefix = localImagePrefix
        self.cacheDirectoryName = cacheDirectoryName
        self.loadWebResource = loadWebResource
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
        // Fundstellen mit Range — derselbe Pfad kann mehrfach vorkommen
        // (`#let x = "…"` und `image("…")`); geladen wird er trotzdem nur einmal.
        let references = TypstImageReferenceScanner.scan(source)
        guard !references.isEmpty else {
            return TypstImageResolutionResult(resolvedSource: source, imageFiles: [])
        }

        var uniquePaths: [String] = []
        var seenPaths = Set<String>()
        for reference in references {
            if seenPaths.insert(reference.path).inserted {
                uniquePaths.append(reference.path)
            }
        }

        var replacementByPath: [String: String] = [:]
        var imageFiles: [ImageFile] = []

        await withTaskGroup(of: (path: String, replacement: String?, imageFile: ImageFile?)?.self) { group in
            for path in uniquePaths {
                group.addTask {
                    await Self.processRef(path, configuration: configuration)
                }
            }

            for await result in group {
                guard let (path, replacement, imageFile) = result else { continue }
                if let imageFile { imageFiles.append(imageFile) }
                if let replacement { replacementByPath[path] = replacement }
            }
        }

        // Nur die gescannten Literale ersetzen — nichts sonst im Dokument.
        let replacements = references.compactMap { reference -> TypstSourceReplacement? in
            guard let text = replacementByPath[reference.path] else { return nil }
            return TypstSourceReplacement(range: reference.range, text: text)
        }

        return TypstImageResolutionResult(
            resolvedSource: TypstSourceRewriter.apply(replacements, to: source),
            imageFiles: imageFiles
        )
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

    // MARK: - Einzelne Referenz verarbeiten

    /// Verarbeitet einen einzelnen Bildpfad-Kandidaten.
    /// - Returns: Tuple aus (path, replacementPath?, imageFile?)
    private static func processRef(
        _ ref: String,
        configuration: TypstImageResolverConfiguration
    ) async -> (String, String?, ImageFile?)? {
        if ref.hasPrefix("http://") || ref.hasPrefix("https://") {
            return await processWebRef(ref, configuration: configuration)
        } else if ref.hasPrefix(configuration.localImagePrefix) {
            return processLocalRef(ref, configuration: configuration)
        }
        // Andere Pfade (z.B. Package-relative) werden ignoriert
        return nil
    }

    // MARK: - Web-Bilder

    /// Lädt eine Web-Ressource und ersetzt die URL durch einen virtuellen Pfad —
    /// aber nur, wenn die Antwort tatsächlich ein Bild ist.
    /// Aus `image("https://example.com/foto.png")` wird `image("__web__/foto.png")`.
    ///
    /// Jeder andere Ausgang (Netzfehler, Status ≠ 2xx, HTML-Seite, Host ohne
    /// Pfad) liefert `nil`, und zwar **ohne Ausgabe**: Kandidaten sind
    /// spekulativ, ein nicht aufgelöster Kandidat ist der Normalfall und kein
    /// Fehler.
    private static func processWebRef(
        _ urlString: String,
        configuration: TypstImageResolverConfiguration
    ) async -> (String, String?, ImageFile?)? {
        guard let url = URL(string: urlString) else { return nil }

        // Kandidaten ohne Pfadanteil (bloßer Host) gar nicht erst laden —
        // sie können kein Bild sein und der Abruf wäre reine Nebenwirkung.
        guard TypstWebImageResponse.hasPath(url) else { return nil }

        do {
            let (data, response) = try await configuration.loadWebResource(url)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode),
                  !data.isEmpty else {
                return nil
            }

            let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type")
            guard let virtualPath = TypstWebImageResponse.imagePath(
                forURL: urlString,
                contentType: contentType,
                data: data
            ) else {
                return nil
            }

            return (urlString, virtualPath, ImageFile(path: virtualPath, content: data))
        } catch {
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
