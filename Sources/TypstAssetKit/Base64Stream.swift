//
//  Base64Stream.swift
//  TypstAssetKit
//
//  Inkrementeller Base64-Decoder und -Encoder.
//
//  `Data(base64Encoded:)` und `Data.base64EncodedString()` brauchen die
//  vollstaendige Ein- bzw. Ausgabe im Speicher. Genau das wollen wir bei
//  30-MB-Dokumenten vermeiden. Diese beiden Typen arbeiten byteweise bzw.
//  chunkweise und haben konstanten Speicherbedarf.
//

import Foundation

// MARK: - Decoder

/// Dekodiert Base64 byteweise. Whitespace wird ignoriert (Typst-Quelltexte
/// enthalten oft umgebrochene Base64-Blöcke). Sowohl gepolsterte als auch
/// ungepolsterte Eingaben werden akzeptiert.
public struct Base64StreamDecoder {
    public enum Failure: Error, Equatable {
        /// Zeichen ausserhalb des Base64-Alphabets.
        case invalidCharacter(UInt8)
        /// Eingabe endet mitten in einer Vierergruppe (1 uebriges Sextett).
        case truncated
        /// Daten nach dem Padding.
        case trailingData
    }

    private var accumulator: UInt32 = 0
    private var sextets: UInt8 = 0
    private var padding: UInt8 = 0
    private var closed = false

    public init() {}

    /// Fuegt ein Eingabezeichen hinzu und haengt fertige Bytes an `out` an.
    public mutating func push(_ byte: UInt8, into out: inout [UInt8]) throws {
        if Base64StreamDecoder.isWhitespace(byte) { return }
        if closed { throw Failure.trailingData }

        if byte == 0x3D { // '='
            guard sextets == 2 || sextets == 3 else { throw Failure.invalidCharacter(byte) }
            accumulator <<= 6
            padding += 1
            sextets += 1
            if sextets == 4 {
                flush(into: &out)
                closed = true
            }
            return
        }

        guard padding == 0, let value = Base64StreamDecoder.value(of: byte) else {
            throw Failure.invalidCharacter(byte)
        }
        accumulator = (accumulator << 6) | UInt32(value)
        sextets += 1
        if sextets == 4 {
            flush(into: &out)
        }
    }

    /// Schliesst den Strom ab und schreibt die letzten Bytes.
    public mutating func finish(into out: inout [UInt8]) throws {
        if closed || sextets == 0 { return }
        switch sextets {
        case 2:
            accumulator <<= 12
            padding = 2
        case 3:
            accumulator <<= 6
            padding = 1
        default:
            throw Failure.truncated
        }
        flush(into: &out)
        closed = true
    }

    private mutating func flush(into out: inout [UInt8]) {
        let byteCount = 3 - Int(padding)
        out.append(UInt8((accumulator >> 16) & 0xFF))
        if byteCount > 1 { out.append(UInt8((accumulator >> 8) & 0xFF)) }
        if byteCount > 2 { out.append(UInt8(accumulator & 0xFF)) }
        accumulator = 0
        sextets = 0
    }

    // MARK: Zeichenklassen

    @inline(__always)
    static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    @inline(__always)
    static func value(of byte: UInt8) -> UInt8? {
        switch byte {
        case 0x41...0x5A: byte - 0x41           // A–Z
        case 0x61...0x7A: byte - 0x61 + 26      // a–z
        case 0x30...0x39: byte - 0x30 + 52      // 0–9
        case 0x2B: 62                            // +
        case 0x2F: 63                            // /
        default: nil
        }
    }

    /// Zeichen, die in einem Base64-Lauf vorkommen duerfen — inklusive
    /// Padding und Whitespace. Wird vom Importer zur Erkennung genutzt.
    @inline(__always)
    public static func isBase64Byte(_ byte: UInt8) -> Bool {
        value(of: byte) != nil || byte == 0x3D || isWhitespace(byte)
    }

    /// Zeichen, die zur Laengenschwelle zaehlen (Whitespace zaehlt nicht mit).
    @inline(__always)
    public static func isSignificantBase64Byte(_ byte: UInt8) -> Bool {
        value(of: byte) != nil || byte == 0x3D
    }
}

// MARK: - Encoder

/// Kodiert Bytes chunkweise nach Base64 (einzeilig, mit Padding).
public struct Base64StreamEncoder {
    private static let alphabet: [UInt8] = Array(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8
    )

    /// Bis zu zwei Bytes, die auf die naechste Dreiergruppe warten.
    private var carry: [UInt8] = []

    public init() {}

    public mutating func push(_ chunk: ArraySlice<UInt8>, into out: inout [UInt8]) {
        out.reserveCapacity(out.count + ((carry.count + chunk.count) / 3) * 4)

        var pending = carry
        pending.append(contentsOf: chunk)

        let fullGroups = (pending.count / 3) * 3
        var index = 0
        while index < fullGroups {
            let group = (UInt32(pending[index]) << 16)
                | (UInt32(pending[index + 1]) << 8)
                | UInt32(pending[index + 2])
            out.append(Base64StreamEncoder.alphabet[Int((group >> 18) & 63)])
            out.append(Base64StreamEncoder.alphabet[Int((group >> 12) & 63)])
            out.append(Base64StreamEncoder.alphabet[Int((group >> 6) & 63)])
            out.append(Base64StreamEncoder.alphabet[Int(group & 63)])
            index += 3
        }

        carry = Array(pending[fullGroups...])
    }

    public mutating func finish(into out: inout [UInt8]) {
        switch carry.count {
        case 1:
            let group = UInt32(carry[0]) << 16
            out.append(Base64StreamEncoder.alphabet[Int((group >> 18) & 63)])
            out.append(Base64StreamEncoder.alphabet[Int((group >> 12) & 63)])
            out.append(0x3D)
            out.append(0x3D)
        case 2:
            let group = (UInt32(carry[0]) << 16) | (UInt32(carry[1]) << 8)
            out.append(Base64StreamEncoder.alphabet[Int((group >> 18) & 63)])
            out.append(Base64StreamEncoder.alphabet[Int((group >> 12) & 63)])
            out.append(Base64StreamEncoder.alphabet[Int((group >> 6) & 63)])
            out.append(0x3D)
        default:
            break
        }
        carry = []
    }
}
