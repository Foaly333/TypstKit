//
//  TypstAssetStoreTests.swift
//  TypstAssetKitTests
//

import Foundation
import Testing

@testable import TypstAssetKit

@Suite("Asset-Store")
struct TypstAssetStoreTests {

    @Test("Pfad folgt der Store-Konvention")
    func pathConvention() throws {
        let temp = try TemporaryDirectory()
        let ref = try temp.store.store(data: Fixtures.onePixelPNG)

        #expect(ref.format == .png)
        #expect(ref.hash.count == TypstAssetRef.hashLength)
        #expect(ref.path == "img/\(ref.hash).png")
        #expect(TypstAssetRef(path: ref.path) == ref)
    }

    @Test("Gleicher Inhalt ergibt genau eine Datei")
    func deduplication() throws {
        let temp = try TemporaryDirectory()
        let store = temp.store

        let first = try store.store(data: Fixtures.onePixelPNG)
        let second = try store.store(data: Fixtures.onePixelPNG)

        #expect(first == second)
        #expect(temp.fileCount(in: "img") == 1)
    }

    @Test("Unterschiedlicher Inhalt ergibt unterschiedliche Hashes")
    func distinctContent() throws {
        let temp = try TemporaryDirectory()
        let store = temp.store

        let png = try store.store(data: Fixtures.png(byteCount: 64))
        let jpeg = try store.store(data: Fixtures.jpeg(byteCount: 64))

        #expect(png.hash != jpeg.hash)
        #expect(png.format == .png)
        #expect(jpeg.format == .jpeg)
        #expect(temp.fileCount(in: "img") == 2)
    }

    @Test("Gespeicherte Bytes kommen unveraendert zurueck")
    func readBack() throws {
        let temp = try TemporaryDirectory()
        let store = temp.store
        let data = Fixtures.png(byteCount: 100_000)

        let ref = try store.store(data: data)
        #expect(try store.data(for: ref) == data)
        #expect(store.contains(ref))
    }

    @Test("Nicht erkennbare Formate werden abgelehnt")
    func rejectsUnknownFormat() throws {
        let temp = try TemporaryDirectory()
        #expect(throws: TypstAssetError.unsupportedFormat) {
            try temp.store.store(data: Data(repeating: 0x00, count: 256))
        }
        // Nichts darf liegengeblieben sein.
        #expect(temp.fileCount(in: "img") == 0)
    }

    @Test("Leere Daten werden abgelehnt")
    func rejectsEmptyData() throws {
        let temp = try TemporaryDirectory()
        #expect(throws: TypstAssetError.unsupportedFormat) {
            try temp.store.store(data: Data())
        }
    }

    @Test("Fehlendes Asset meldet sich")
    func missingAsset() throws {
        let temp = try TemporaryDirectory()
        let ref = TypstAssetRef(hash: String(repeating: "a", count: 32), format: .png)
        #expect(throws: TypstAssetError.missingAsset(ref.path)) {
            try temp.store.data(for: ref)
        }
    }

    @Test("Garbage Collection loescht nur Unreferenziertes")
    func garbageCollection() throws {
        let temp = try TemporaryDirectory()
        let store = temp.store

        let kept = try store.store(data: Fixtures.png(byteCount: 64))
        let orphan = try store.store(data: Fixtures.jpeg(byteCount: 64))

        let deleted = try store.collectGarbage(referenced: [kept])

        #expect(deleted == [orphan])
        #expect(store.contains(kept))
        #expect(!store.contains(orphan))
        #expect(try store.allAssets() == [kept])
    }

    @Test("Ungueltige Pfade parsen nicht", arguments: [
        "img/zzzz.png",                                   // kein Hex
        "img/abc.png",                                    // zu kurz
        "images/00112233445566778899aabbccddeeff.png",    // falsches Verzeichnis
        "img/00112233445566778899aabbccddeeff.txt",       // kein Bildformat
        "img/00112233445566778899AABBCCDDEEFF.png",       // Grossbuchstaben
        "img/00112233445566778899aabbccddeeff.jpeg",      // nicht die kanonische Endung
        "img/00112233445566778899aabbccddeeff",           // keine Endung
    ])
    func rejectsInvalidPaths(path: String) {
        #expect(TypstAssetRef(path: path) == nil)
    }
}
