//
//  TypstAssetStore.swift
//  TypstAssetKit
//
//  Content-addressed Bild-Store.
//
//  Layout:
//      <root>/img/<sha256-128bit-hex>.<ext>
//
//  `root` ist typischerweise das Documents-Verzeichnis des iCloud-Containers,
//  also genau das Verzeichnis, in dem `TypstImageResolver.processLocalRef`
//  ohnehin schon nach `img/…` sucht.
//
//  Schreiboperationen sind idempotent: existiert der Zielpfad bereits, ist der
//  Inhalt per Konstruktion identisch und der Schreibvorgang entfaellt. Deshalb
//  braucht der Store keinen Lock und ist ein simpler Wertetyp.
//

import CryptoKit
import Foundation

public enum TypstAssetError: Error, Equatable {
    /// Die Bytes gehoeren zu keinem unterstuetzten Bildformat.
    case unsupportedFormat
    /// Der Asset-Pfad existiert nicht im Store.
    case missingAsset(String)
    /// Der Pfad entspricht nicht der Store-Konvention.
    case invalidAssetPath(String)
}

public struct TypstAssetStore: Sendable {
    /// Wurzel, unterhalb derer das `img/`-Verzeichnis liegt.
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// Verzeichnis der Bilddateien.
    public var assetDirectory: URL {
        root.appendingPathComponent(TypstAssetRef.directoryName, isDirectory: true)
    }

    public func url(for ref: TypstAssetRef) -> URL {
        root.appendingPathComponent(ref.path)
    }

    public func contains(_ ref: TypstAssetRef) -> Bool {
        FileManager.default.fileExists(atPath: url(for: ref).path)
    }

    // MARK: - Schreiben

    /// Legt Bilddaten ab, die bereits vollstaendig im Speicher liegen.
    @discardableResult
    public func store(data: Data) throws -> TypstAssetRef {
        let writer = try beginWrite()
        do {
            try writer.append(Array(data))
            return try writer.commit()
        } catch {
            writer.discard()
            throw error
        }
    }

    /// Beginnt einen streamenden Schreibvorgang. Die Bytes landen zuerst in
    /// einer temporaeren Datei; `commit()` verschiebt sie an ihren
    /// inhaltsadressierten Zielpfad.
    public func beginWrite() throws -> TypstAssetWriter {
        try TypstAssetWriter(store: self)
    }

    // MARK: - Lesen

    public func data(for ref: TypstAssetRef) throws -> Data {
        guard let data = try? Data(contentsOf: url(for: ref)) else {
            throw TypstAssetError.missingAsset(ref.path)
        }
        return data
    }

    /// Streamende Quelle fuer den Exporter — das Bild wird nie am Stueck geladen.
    public func byteSource(for ref: TypstAssetRef) throws -> TypstByteSource {
        guard contains(ref) else { throw TypstAssetError.missingAsset(ref.path) }
        return try TypstFileByteSource(url: url(for: ref))
    }

    // MARK: - Bestand & Aufraeumen

    /// Alle im Store liegenden Referenzen.
    public func allAssets() throws -> Set<TypstAssetRef> {
        let fm = FileManager.default
        guard fm.fileExists(atPath: assetDirectory.path) else { return [] }
        let files = try fm.contentsOfDirectory(at: assetDirectory, includingPropertiesForKeys: nil)
        return Set(files.compactMap { file in
            TypstAssetRef(path: "\(TypstAssetRef.directoryName)/\(file.lastPathComponent)")
        })
    }

    /// Loescht alle Assets, die in `referenced` nicht vorkommen.
    ///
    /// `referenced` muss die Vereinigung ueber *alle* Dokumente sein —
    /// wegen der Deduplizierung teilen sich Dokumente ihre Bilder.
    /// - Returns: die geloeschten Referenzen.
    @discardableResult
    public func collectGarbage(referenced: Set<TypstAssetRef>) throws -> [TypstAssetRef] {
        let orphans = try allAssets().subtracting(referenced)
        for ref in orphans {
            try FileManager.default.removeItem(at: url(for: ref))
        }
        return orphans.sorted { $0.hash < $1.hash }
    }
}

// MARK: - Writer

/// Streamender Schreibvorgang: hasht und schnueffelt das Format waehrend
/// die Bytes bereits auf die Platte laufen.
public final class TypstAssetWriter {
    private let store: TypstAssetStore
    private let temporaryURL: URL
    private let handle: FileHandle
    private var hasher = SHA256()
    private var head: [UInt8] = []
    private var byteCount = 0
    private var finished = false

    fileprivate init(store: TypstAssetStore) throws {
        self.store = store
        self.temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("typst-asset-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: temporaryURL.path, contents: nil)
        self.handle = try FileHandle(forWritingTo: temporaryURL)
        self.head.reserveCapacity(TypstImageFormat.sniffLength)
    }

    public func append(_ bytes: [UInt8]) throws {
        guard !bytes.isEmpty else { return }
        if head.count < TypstImageFormat.sniffLength {
            head.append(contentsOf: bytes.prefix(TypstImageFormat.sniffLength - head.count))
        }
        bytes.withUnsafeBytes { hasher.update(bufferPointer: $0) }
        try handle.write(contentsOf: Data(bytes))
        byteCount += bytes.count
    }

    /// Schliesst ab und verschiebt die Datei an ihren Zielpfad.
    /// Existiert dieser bereits, wird die temporaere Datei verworfen (Dedup).
    public func commit() throws -> TypstAssetRef {
        precondition(!finished, "TypstAssetWriter darf nur einmal abgeschlossen werden")
        finished = true
        try handle.close()

        guard byteCount > 0, let format = TypstImageFormat.sniff(head) else {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw TypstAssetError.unsupportedFormat
        }

        let digest = hasher.finalize()
        let hash = digest.prefix(TypstAssetRef.hashLength / 2)
            .map { String(format: "%02x", $0) }
            .joined()
        let ref = TypstAssetRef(hash: hash, format: format)

        let destination = store.url(for: ref)
        let fm = FileManager.default

        if fm.fileExists(atPath: destination.path) {
            try? fm.removeItem(at: temporaryURL)
            return ref
        }

        try fm.createDirectory(at: store.assetDirectory, withIntermediateDirectories: true)
        do {
            try fm.moveItem(at: temporaryURL, to: destination)
        } catch {
            // Wettlauf mit einem parallelen Schreibvorgang desselben Bildes:
            // Inhalt ist identisch, also ist das Ziel bereits korrekt.
            guard fm.fileExists(atPath: destination.path) else { throw error }
            try? fm.removeItem(at: temporaryURL)
        }
        return ref
    }

    /// Bricht ab und raeumt die temporaere Datei weg.
    public func discard() {
        guard !finished else { return }
        finished = true
        try? handle.close()
        try? FileManager.default.removeItem(at: temporaryURL)
    }
}
