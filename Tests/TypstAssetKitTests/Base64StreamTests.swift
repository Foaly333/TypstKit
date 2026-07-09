//
//  Base64StreamTests.swift
//  TypstAssetKitTests
//

import Foundation
import Testing

@testable import TypstAssetKit

@Suite("Base64-Stream")
struct Base64StreamTests {

    @Test("Encoder stimmt mit Foundation ueberein", arguments: 0...16)
    func encoderMatchesFoundation(byteCount: Int) {
        let bytes = Array(Fixtures.png(byteCount: max(byteCount, 0)).prefix(byteCount))
        #expect(encodeAll(bytes) == Data(bytes).base64EncodedString())
    }

    @Test("Encoder ist unabhaengig von der Chunk-Groesse", arguments: [1, 2, 3, 5, 64, 4096])
    func encoderIsChunkIndependent(chunkSize: Int) {
        let bytes = Array(Fixtures.png(byteCount: 5_000))
        #expect(encodeChunked(bytes, chunkSize: chunkSize) == Data(bytes).base64EncodedString())
    }

    @Test("Decoder kehrt den Encoder um", arguments: [0, 1, 2, 3, 4, 5, 255, 4096])
    func roundTrip(byteCount: Int) throws {
        let bytes = Array(Fixtures.png(byteCount: byteCount).prefix(byteCount))
        #expect(try decodeAll(encodeAll(bytes)) == bytes)
    }

    @Test("Decoder ignoriert Whitespace")
    func decoderIgnoresWhitespace() throws {
        let bytes = Array(Fixtures.onePixelPNG)
        let wrapped = encodeAll(bytes)
            .chunked(into: 20)
            .joined(separator: "\n  ")
        #expect(try decodeAll(wrapped) == bytes)
    }

    @Test("Decoder akzeptiert Eingaben ohne Padding")
    func decoderAcceptsUnpadded() throws {
        // 4 Bytes → 6 Sextette → mit Padding "…=="; ohne Padding muss es auch gehen.
        let bytes: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF]
        let padded = Data(bytes).base64EncodedString()
        let unpadded = padded.replacingOccurrences(of: "=", with: "")
        #expect(try decodeAll(unpadded) == bytes)
    }

    @Test("Decoder weist Fremdzeichen zurueck")
    func decoderRejectsInvalidCharacter() {
        #expect(throws: Base64StreamDecoder.Failure.invalidCharacter(0x21)) {
            try decodeAll("AAAA!AAA")
        }
    }

    @Test("Decoder erkennt abgeschnittene Eingabe")
    func decoderRejectsTruncated() {
        // Ein einzelnes Sextett kann kein Byte ergeben.
        #expect(throws: Base64StreamDecoder.Failure.truncated) {
            try decodeAll("AAAAA")
        }
    }

    @Test("Decoder weist Daten nach dem Padding zurueck")
    func decoderRejectsTrailingData() {
        #expect(throws: Base64StreamDecoder.Failure.trailingData) {
            try decodeAll("AA==AA==")
        }
    }

    @Test("Zeichenklassen")
    func characterClasses() {
        #expect(Base64StreamDecoder.isBase64Byte(UInt8(ascii: "A")))
        #expect(Base64StreamDecoder.isBase64Byte(UInt8(ascii: "=")))
        #expect(Base64StreamDecoder.isBase64Byte(UInt8(ascii: "\n")))
        #expect(!Base64StreamDecoder.isBase64Byte(UInt8(ascii: ".")))
        #expect(!Base64StreamDecoder.isSignificantBase64Byte(UInt8(ascii: "\n")))
        #expect(Base64StreamDecoder.isSignificantBase64Byte(UInt8(ascii: "=")))
    }
}

private extension String {
    func chunked(into size: Int) -> [String] {
        var result: [String] = []
        var index = startIndex
        while index < endIndex {
            let end = self.index(index, offsetBy: size, limitedBy: endIndex) ?? endIndex
            result.append(String(self[index..<end]))
            index = end
        }
        return result
    }
}
