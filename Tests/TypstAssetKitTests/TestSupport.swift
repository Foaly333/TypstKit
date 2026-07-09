//
//  TestSupport.swift
//  TypstAssetKitTests
//

import Foundation
import Testing

@testable import TypstAssetKit

// MARK: - Temporaeres Verzeichnis

/// Raeumt sich beim Deinit selbst auf.
final class TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("typstassetkit-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    var store: TypstAssetStore { TypstAssetStore(root: url) }

    func fileCount(in subdirectory: String) -> Int {
        let dir = url.appendingPathComponent(subdirectory)
        let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        return files?.count ?? 0
    }
}

// MARK: - Fixtures

enum Fixtures {
    /// Ein echtes 1×1-PNG (96 Base64-Zeichen).
    static let onePixelPNGBase64 =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="

    static var onePixelPNG: Data {
        Data(base64Encoded: onePixelPNGBase64)!
    }

    /// Deterministisches „PNG“ beliebiger Groesse: korrekte Magic Bytes,
    /// danach reproduzierbares Fuellmaterial.
    static func png(byteCount: Int, seed: UInt8 = 7) -> Data {
        var bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        var value = seed
        while bytes.count < byteCount {
            value = value &* 31 &+ 17
            bytes.append(value)
        }
        return Data(bytes)
    }

    static func jpeg(byteCount: Int) -> Data {
        var bytes: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0]
        var value: UInt8 = 3
        while bytes.count < byteCount {
            value = value &* 17 &+ 5
            bytes.append(value)
        }
        return Data(bytes)
    }

    /// Die Testschwelle liegt niedriger als die Produktionsschwelle (200),
    /// damit das 1×1-PNG (96 Zeichen) als Blob erkannt wird.
    static let syntax = TypstInlineImageSyntax(minimumBase64Length: 32)

    static let importLine = #"#import "@preview/based:0.2.0": base64"#
}

// MARK: - Base64-Helfer

func decodeAll(_ text: String) throws -> [UInt8] {
    var decoder = Base64StreamDecoder()
    var out: [UInt8] = []
    for byte in Array(text.utf8) {
        try decoder.push(byte, into: &out)
    }
    try decoder.finish(into: &out)
    return out
}

func encodeAll(_ bytes: [UInt8]) -> String {
    var encoder = Base64StreamEncoder()
    var out: [UInt8] = []
    encoder.push(bytes[...], into: &out)
    encoder.finish(into: &out)
    return String(decoding: out, as: UTF8.self)
}

/// Kodiert chunkweise — prueft, dass die Chunk-Grenzen egal sind.
func encodeChunked(_ bytes: [UInt8], chunkSize: Int) -> String {
    var encoder = Base64StreamEncoder()
    var out: [UInt8] = []
    var index = 0
    while index < bytes.count {
        let end = min(bytes.count, index + chunkSize)
        encoder.push(bytes[index..<end], into: &out)
        index = end
    }
    encoder.finish(into: &out)
    return String(decoding: out, as: UTF8.self)
}
