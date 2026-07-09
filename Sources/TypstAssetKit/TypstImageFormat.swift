//
//  TypstImageFormat.swift
//  TypstAssetKit
//
//  Formaterkennung anhand der Magic Bytes.
//
//  Wichtig fuer den Importer: Base64-Strings, die *kein* Bild sind
//  (z.B. eingebettete Schriften oder beliebige Daten), werden hier
//  nicht erkannt — der Importer laesst sie daraufhin unveraendert stehen.
//

import Foundation

public enum TypstImageFormat: String, Sendable, CaseIterable {
    case png
    case jpeg
    case gif
    case webp
    case svg
    case pdf

    /// Dateiendung im Asset-Store.
    public var fileExtension: String {
        switch self {
        case .png: "png"
        case .jpeg: "jpg"
        case .gif: "gif"
        case .webp: "webp"
        case .svg: "svg"
        case .pdf: "pdf"
        }
    }

    /// So viele Bytes braucht `sniff(_:)` maximal.
    public static let sniffLength = 16

    public static func from(fileExtension ext: String) -> TypstImageFormat? {
        switch ext.lowercased() {
        case "png": .png
        case "jpg", "jpeg": .jpeg
        case "gif": .gif
        case "webp": .webp
        case "svg": .svg
        case "pdf": .pdf
        default: nil
        }
    }

    /// Erkennt das Format an den ersten Bytes. `nil` = kein unterstuetztes Bild.
    public static func sniff(_ bytes: some Collection<UInt8>) -> TypstImageFormat? {
        let head = Array(bytes.prefix(sniffLength))

        if head.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return .png }
        if head.starts(with: [0xFF, 0xD8, 0xFF]) { return .jpeg }
        if head.starts(with: Array("GIF87a".utf8)) || head.starts(with: Array("GIF89a".utf8)) { return .gif }
        if head.count >= 12,
           head.starts(with: Array("RIFF".utf8)),
           Array(head[8..<12]) == Array("WEBP".utf8) { return .webp }
        if head.starts(with: Array("%PDF-".utf8)) { return .pdf }

        // SVG: erstes nicht-leeres Zeichen ist '<' (XML-Deklaration oder <svg).
        if let first = head.first(where: { !Base64StreamDecoder.isWhitespace($0) }), first == 0x3C {
            return .svg
        }

        return nil
    }
}
