//
//  TypstAssetRef.swift
//  TypstAssetKit
//
//  Referenz auf ein Bild im content-addressed Store.
//
//  Der Dateiname ist der gekuerzte SHA-256 des *dekodierten* Bildes.
//  Daraus folgen zwei Eigenschaften, auf die sich Importer und Exporter
//  verlassen:
//
//  1. Deduplizierung — dasselbe Bild in zwanzig Dokumenten belegt eine Datei.
//  2. Nachweisbarer Round-Trip — Export → Import ergibt denselben Hash.
//
//  Das Praefix „img/“ entspricht `TypstImageResolverConfiguration.localImagePrefix`,
//  sodass der bestehende Resolver die Pfade ohne Anpassung aufloest.
//

import Foundation

public struct TypstAssetRef: Hashable, Sendable {
    /// Verzeichnisname relativ zur Store-Wurzel.
    public static let directoryName = "img"

    /// Laenge des Hex-Hashes im Dateinamen (128 Bit).
    public static let hashLength = 32

    /// Gekuerzter SHA-256 des Bildinhalts, hex, Kleinbuchstaben.
    public let hash: String

    public let format: TypstImageFormat

    public init(hash: String, format: TypstImageFormat) {
        self.hash = hash
        self.format = format
    }

    /// Pfad, wie er im Typst-Quelltext steht: `img/<hash>.<ext>`
    public var path: String {
        "\(Self.directoryName)/\(hash).\(format.fileExtension)"
    }

    /// Parst einen Pfad zurueck in eine Referenz. `nil`, wenn er nicht
    /// exakt der Store-Konvention entspricht.
    public init?(path: String) {
        let prefix = "\(Self.directoryName)/"
        guard path.hasPrefix(prefix) else { return nil }

        let name = path.dropFirst(prefix.count)
        guard let dot = name.lastIndex(of: ".") else { return nil }

        let hash = String(name[name.startIndex..<dot])
        let ext = String(name[name.index(after: dot)...])

        guard hash.count == Self.hashLength,
              hash.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
              let format = TypstImageFormat.from(fileExtension: ext),
              format.fileExtension == ext
        else { return nil }

        self.hash = hash
        self.format = format
    }
}
