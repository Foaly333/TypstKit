//
//  TypstPackageManager.swift
//  TypstCompilerKit
//
//  Laedt Typst-Packages aus dem offiziellen Registry herunter,
//  entpackt die tar.gz-Archive und cached sie lokal.
//  Stellt die Package-Dateien als [PackageFile] fuer die FFI bereit.
//

import Compression
import Foundation

/// Beschreibt ein benoetigtes Typst-Package (aus #import geparst).
public struct TypstPackageSpec: Hashable, Sendable {
    public let namespace: String
    public let name: String
    public let version: String

    public init(namespace: String, name: String, version: String) {
        self.namespace = namespace
        self.name = name
        self.version = version
    }
}

/// Verwaltet den Download und Cache von Typst-Packages.
@Observable
public final class TypstPackageManager {
    /// Bereits geladene Package-Dateien (im Speicher gecacht).
    private var loadedPackages: [TypstPackageSpec: [PackageFile]] = [:]

    /// Basis-URL des Typst-Package-Registrys.
    private let registryBaseURL = "https://packages.typst.org"

    /// Cache-Verzeichnis fuer heruntergeladene Packages.
    private let cacheDirectory: URL

    public init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        self.cacheDirectory = caches.appendingPathComponent("TypstPackages", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    /// Scannt Typst-Quelltext nach #import "@namespace/name:version" und gibt die Specs zurueck.
    public static func scanImports(in source: String) -> Set<TypstPackageSpec> {
        var specs = Set<TypstPackageSpec>()
        // Pattern: #import "@namespace/name:version"
        let pattern = #"#import\s+"@([^/]+)/([^:]+):([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return specs }

        let nsRange = NSRange(source.startIndex..., in: source)
        let matches = regex.matches(in: source, range: nsRange)

        for match in matches {
            guard match.numberOfRanges == 4,
                  let nsRange = Range(match.range(at: 1), in: source),
                  let nameRange = Range(match.range(at: 2), in: source),
                  let versionRange = Range(match.range(at: 3), in: source)
            else { continue }

            specs.insert(TypstPackageSpec(
                namespace: String(source[nsRange]),
                name: String(source[nameRange]),
                version: String(source[versionRange])
            ))
        }

        return specs
    }

    /// Laedt alle benoetigten Packages fuer den gegebenen Quelltext,
    /// einschliesslich transitiver Abhaengigkeiten aus Package-Dateien.
    public func resolvePackages(for source: String) async throws -> [PackageFile] {
        var allFiles: [PackageFile] = []
        var resolvedSpecs = Set<TypstPackageSpec>()
        var pendingSpecs = Self.scanImports(in: source)

        while !pendingSpecs.isEmpty {
            let currentBatch = pendingSpecs
            pendingSpecs = []

            for spec in currentBatch where !resolvedSpecs.contains(spec) {
                resolvedSpecs.insert(spec)
                let files = try await resolvePackage(spec)
                allFiles.append(contentsOf: files)

                // Transitive Abhaengigkeiten aus .typ-Dateien scannen
                for file in files where file.path.hasSuffix(".typ") {
                    if let typContent = String(data: file.content, encoding: .utf8) {
                        let transitiveDeps = Self.scanImports(in: typContent)
                        for dep in transitiveDeps where !resolvedSpecs.contains(dep) {
                            pendingSpecs.insert(dep)
                        }
                    }
                }
            }
        }

        return allFiles
    }

    /// Laedt ein einzelnes Package (aus Cache oder Download).
    private func resolvePackage(_ spec: TypstPackageSpec) async throws -> [PackageFile] {
        // Im-Memory-Cache pruefen
        if let cached = loadedPackages[spec] {
            return cached
        }

        // Dateisystem-Cache pruefen
        let packageDir = cacheDirectory
            .appendingPathComponent(spec.namespace, isDirectory: true)
            .appendingPathComponent(spec.name, isDirectory: true)
            .appendingPathComponent(spec.version, isDirectory: true)

        if FileManager.default.fileExists(atPath: packageDir.path) {
            let files = try loadPackageFiles(from: packageDir, spec: spec)
            loadedPackages[spec] = files
            return files
        }

        // Herunterladen und entpacken
        let files = try await downloadAndExtract(spec, to: packageDir)
        loadedPackages[spec] = files
        return files
    }

    /// Laedt ein Package vom Registry herunter und entpackt es.
    private func downloadAndExtract(
        _ spec: TypstPackageSpec,
        to packageDir: URL
    ) async throws -> [PackageFile] {
        let urlString = "\(registryBaseURL)/\(spec.namespace)/\(spec.name)-\(spec.version).tar.gz"
        guard let url = URL(string: urlString) else {
            throw TypstPackageError.invalidURL(urlString)
        }

        let (data, response) = try await URLSession.shared.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw TypstPackageError.downloadFailed(spec.name, spec.version, code)
        }

        // Gzip dekomprimieren
        let tarData = try decompressGzip(data)

        // Tar entpacken ins Zielverzeichnis
        try FileManager.default.createDirectory(at: packageDir, withIntermediateDirectories: true)
        try extractTar(tarData, to: packageDir)

        // Dateien laden und zurueckgeben
        return try loadPackageFiles(from: packageDir, spec: spec)
    }

    /// Laedt alle Dateien eines Packages aus dem Cache-Verzeichnis.
    /// Erkennt und entfernt ein eventuelles Top-Level-Verzeichnis aus dem tar-Archiv,
    /// damit Pfade wie "typst.toml" statt "cades-0.3.1/typst.toml" entstehen.
    private func loadPackageFiles(
        from directory: URL,
        spec: TypstPackageSpec
    ) throws -> [PackageFile] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var files: [PackageFile] = []
        // pathComponents statt String-Replacement: auf iOS ist /var ein Symlink
        // zu /private/var, was zu unterschiedlichen Pfad-Praefixen fuehren kann.
        let baseComponentCount = directory.resolvingSymlinksInPath().pathComponents.count

        for case let fileURL as URL in enumerator {
            let resourceValues = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard resourceValues.isRegularFile == true else { continue }

            let relativePath = fileURL.resolvingSymlinksInPath().pathComponents
                .dropFirst(baseComponentCount)
                .joined(separator: "/")
            let content = try Data(contentsOf: fileURL)

            files.append(PackageFile(
                namespace: spec.namespace,
                name: spec.name,
                version: spec.version,
                path: relativePath,
                content: content
            ))
        }

        // Wenn kein typst.toml auf oberster Ebene existiert, liegt wahrscheinlich
        // ein Top-Level-Verzeichnis aus dem tar-Archiv vor. Praefix entfernen.
        let hasRootManifest = files.contains { $0.path == "typst.toml" }
        if !hasRootManifest, let prefix = detectCommonPrefix(in: files) {
            files = files.map { file in
                PackageFile(
                    namespace: file.namespace,
                    name: file.name,
                    version: file.version,
                    path: String(file.path.dropFirst(prefix.count)),
                    content: file.content
                )
            }
        }

        return files
    }

    /// Erkennt ein gemeinsames Verzeichnis-Praefix aller Dateipfade (z.B. "cades-0.3.1/").
    private func detectCommonPrefix(in files: [PackageFile]) -> String? {
        guard let first = files.first?.path,
              let slashIndex = first.firstIndex(of: "/") else { return nil }

        let prefix = String(first[...slashIndex]) // inkl. "/"
        let allMatch = files.allSatisfy { $0.path.hasPrefix(prefix) }
        return allMatch ? prefix : nil
    }

    /// Entfernt den gesamten Package-Cache.
    public func clearCache() throws {
        try FileManager.default.removeItem(at: cacheDirectory)
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        loadedPackages.removeAll()
    }
}

// MARK: - Gzip-Dekompression

private extension TypstPackageManager {
    /// Dekomprimiert Gzip-Daten durch Entfernen des Gzip-Headers und Dekompression des rohen DEFLATE-Streams.
    /// `NSData.decompressed(using: .zlib)` erwartet rohe DEFLATE-Daten ohne Header,
    /// daher muss der Gzip-Header (RFC 1952) manuell uebersprungen werden.
    func decompressGzip(_ data: Data) throws -> Data {
        // Gzip-Header pruefen (Magic Bytes: 0x1F 0x8B)
        guard data.count >= 10, data[0] == 0x1F, data[1] == 0x8B else {
            throw TypstPackageError.invalidArchive("Keine gueltige Gzip-Datei")
        }

        // Gzip-Header parsen um den Start des DEFLATE-Streams zu finden
        var offset = 10 // Basis-Header ist 10 Bytes

        let flags = data[3]
        let fhcrc    = (flags & 0x02) != 0
        let fextra   = (flags & 0x04) != 0
        let fname    = (flags & 0x08) != 0
        let fcomment = (flags & 0x10) != 0

        // FEXTRA: 2-Byte Laenge + Extra-Daten
        if fextra {
            guard offset + 2 <= data.count else {
                throw TypstPackageError.invalidArchive("Gzip FEXTRA-Feld unvollstaendig")
            }
            let extraLen = Int(data[offset]) | (Int(data[offset + 1]) << 8)
            offset += 2 + extraLen
        }

        // FNAME: Null-terminierter String
        if fname {
            while offset < data.count && data[offset] != 0 { offset += 1 }
            offset += 1 // Null-Byte ueberspringen
        }

        // FCOMMENT: Null-terminierter String
        if fcomment {
            while offset < data.count && data[offset] != 0 { offset += 1 }
            offset += 1
        }

        // FHCRC: 2-Byte CRC16 des Headers
        if fhcrc {
            offset += 2
        }

        guard offset < data.count, data.count >= offset + 8 else {
            throw TypstPackageError.invalidArchive("Gzip-Datei zu kurz")
        }

        // Originalgroesse aus dem 8-Byte-Trailer lesen (letzte 4 Bytes, little-endian)
        let trailerOffset = data.count - 4
        let originalSize = Int(data[trailerOffset])
            | (Int(data[trailerOffset + 1]) << 8)
            | (Int(data[trailerOffset + 2]) << 16)
            | (Int(data[trailerOffset + 3]) << 24)

        // Roher DEFLATE-Stream: zwischen Header und 8-Byte-Trailer (CRC32 + Originalgroesse)
        let deflateData = data[offset..<(data.count - 8)]

        // Dekompression via Compression-Framework (zuverlaessiger als NSData fuer rohe DEFLATE-Streams)
        let decompressed = try decompressDeflate(deflateData, expectedSize: originalSize)
        return decompressed
    }

    /// Dekomprimiert einen rohen DEFLATE-Stream mit dem Compression-Framework.
    private func decompressDeflate(_ data: Data, expectedSize: Int) throws -> Data {
        // Puffergroesse: mindestens expectedSize, aber auch genug Platz fuer unerwartete Daten
        let bufferSize = max(expectedSize, data.count * 4)
        let destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { destinationBuffer.deallocate() }

        let decodedSize = data.withUnsafeBytes { sourcePtr -> Int in
            guard let baseAddress = sourcePtr.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return 0
            }
            return compression_decode_buffer(
                destinationBuffer,
                bufferSize,
                baseAddress,
                data.count,
                nil,
                COMPRESSION_ZLIB
            )
        }

        guard decodedSize > 0 else {
            throw TypstPackageError.invalidArchive("DEFLATE-Dekompression fehlgeschlagen")
        }

        return Data(bytes: destinationBuffer, count: decodedSize)
    }
}

// MARK: - Tar-Extraktion

private extension TypstPackageManager {
    /// Entpackt ein TAR-Archiv in das angegebene Verzeichnis.
    /// Implementiert das grundlegende POSIX-TAR-Format (512-Byte-Bloecke).
    func extractTar(_ data: Data, to directory: URL) throws {
        var offset = 0

        while offset + 512 <= data.count {
            let headerBlock = data[offset..<(offset + 512)]

            // Leerer Block = Ende des Archivs
            if headerBlock.allSatisfy({ $0 == 0 }) {
                break
            }

            // Dateiname extrahieren (Bytes 0-99 + ggf. Prefix 345-499 fuer USTAR)
            let nameData = data[offset..<(offset + 100)]
            var fileName = String(bytes: nameData.prefix(while: { $0 != 0 }), encoding: .utf8) ?? ""

            // USTAR-Prefix (Bytes 345-499) fuer lange Pfade
            let ustarMarker = data[(offset + 257)..<(offset + 263)]
            if String(bytes: ustarMarker, encoding: .utf8)?.hasPrefix("ustar") == true {
                let prefixData = data[(offset + 345)..<(offset + 500)]
                let prefix = String(bytes: prefixData.prefix(while: { $0 != 0 }), encoding: .utf8) ?? ""
                if !prefix.isEmpty {
                    fileName = prefix + "/" + fileName
                }
            }

            // Dateigroesse aus dem Oktal-Feld (Bytes 124-135)
            let sizeData = data[(offset + 124)..<(offset + 136)]
            let sizeString = String(bytes: sizeData.prefix(while: { $0 != 0 }), encoding: .utf8)?
                .trimmingCharacters(in: .whitespaces) ?? "0"
            let fileSize = Int(sizeString, radix: 8) ?? 0

            // Dateityp (Byte 156): '0' oder '\0' = regulaere Datei, '5' = Verzeichnis
            let typeFlag = data[offset + 156]

            offset += 512 // Header ueberspringen

            if (typeFlag == 0x30 || typeFlag == 0x00) && fileSize > 0 && !fileName.isEmpty {
                // Regulaere Datei extrahieren
                let fileData = data[offset..<(offset + fileSize)]
                let filePath = directory.appendingPathComponent(fileName)

                // Uebergeordnete Verzeichnisse erstellen
                try FileManager.default.createDirectory(
                    at: filePath.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )

                try fileData.write(to: filePath)
            }

            // Zum naechsten 512-Byte-Block springen
            let blocks = (fileSize + 511) / 512
            offset += blocks * 512
        }
    }
}

// MARK: - Fehlertypen

public enum TypstPackageError: LocalizedError {
    case invalidURL(String)
    case downloadFailed(String, String, Int)
    case invalidArchive(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let url):
            return "Ungueltige Package-URL: \(url)"
        case .downloadFailed(let name, let version, let code):
            return "Download fehlgeschlagen fuer \(name):\(version) (HTTP \(code))"
        case .invalidArchive(let detail):
            return "Ungueltiges Archiv: \(detail)"
        }
    }
}
