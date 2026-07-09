//
//  TypstDocumentExporter.swift
//  TypstAssetKit
//
//  Erzeugt aus einem importierten Dokument wieder selbstenthaltenden
//  Typst-Quelltext mit eingebetteten Base64-Bildern.
//
//  Die Asymmetrie zum Importer ist Absicht:
//  - Die *Eingabe* des Exporters ist ein importiertes Dokument, also klein
//    (Kilobyte). Sie darf im Speicher liegen.
//  - Die *Ausgabe* enthaelt die Bilder und ist gross. Sie wird gestreamt;
//    die Base64-Zeichen wandern chunkweise aus der Bilddatei in die Senke.
//
//  Umkehrregel — eine einzige, kontextfrei:
//      "img/….png"   →   base64.decode("iVBOR…")
//
//  Damit wird aus `#let x = "img/….png"` automatisch
//  `#let x = base64.decode("iVBOR…")` und aus `image("img/….png")`
//  wird `image(base64.decode("iVBOR…"))` — ohne dass der Exporter
//  Bezeichner umschreiben oder Code- von Textmodus unterscheiden muesste.
//  Ein Wort wie „logo“ im Fliesstext bleibt garantiert unberuehrt.
//

import Foundation

public enum TypstDocumentExporter {

    // MARK: - Öffentliche API

    /// Exportiert nach `sink`. Die Bilder werden gestreamt.
    /// - Returns: Anzahl der eingebetteten Bilder.
    @discardableResult
    public static func export(
        source: String,
        store: TypstAssetStore,
        into sink: TypstByteSink,
        syntax: TypstInlineImageSyntax = .default
    ) throws -> Int {
        let exporter = Exporter(source: source, store: store, sink: sink, syntax: syntax)
        let count = try exporter.run()
        try sink.finish()
        return count
    }

    /// Exportiert in eine Datei.
    @discardableResult
    public static func exportFile(
        source: String,
        store: TypstAssetStore,
        to url: URL,
        syntax: TypstInlineImageSyntax = .default
    ) throws -> Int {
        try export(source: source, store: store, into: TypstFileByteSink(url: url), syntax: syntax)
    }

    /// Exportiert in einen String — fuer die Zwischenablage.
    /// Hier entsteht der grosse Puffer notgedrungen; das ist der einzige Ort.
    public static func exportToString(
        source: String,
        store: TypstAssetStore,
        syntax: TypstInlineImageSyntax = .default
    ) throws -> String {
        let sink = TypstDataByteSink()
        try export(source: source, store: store, into: sink, syntax: syntax)
        return sink.string
    }

    // MARK: - Analyse

    /// Alle Store-Referenzen, die ein Quelltext benutzt.
    /// Grundlage fuer `TypstAssetStore.collectGarbage(referenced:)`.
    public static func assetReferences(in source: String) -> Set<TypstAssetRef> {
        let bytes = Array(source.utf8)
        var refs: Set<TypstAssetRef> = []
        var index = 0

        while index < bytes.count {
            guard bytes[index] == 0x22 else {
                index += 1
                continue
            }
            if let (ref, end) = parseAssetLiteral(bytes, from: index) {
                refs.insert(ref)
                index = end
            } else {
                index = skipLiteral(bytes, from: index)
            }
        }
        return refs
    }
}

// MARK: - Literal-Helfer

/// Erwartet `bytes[start] == '"'`. Liefert die Referenz und den Index
/// hinter dem schliessenden Anfuehrungszeichen.
private func parseAssetLiteral(_ bytes: [UInt8], from start: Int) -> (TypstAssetRef, Int)? {
    var index = start + 1
    var content: [UInt8] = []
    while index < bytes.count, content.count <= 128 {
        let byte = bytes[index]
        if byte == 0x22 {
            guard let ref = TypstAssetRef(path: String(decoding: content, as: UTF8.self)) else { return nil }
            return (ref, index + 1)
        }
        if byte == 0x5C { return nil }
        content.append(byte)
        index += 1
    }
    return nil
}

/// Ueberspringt ein String-Literal inklusive Escapes.
private func skipLiteral(_ bytes: [UInt8], from start: Int) -> Int {
    var index = start + 1
    while index < bytes.count {
        let byte = bytes[index]
        if byte == 0x5C { index += 2; continue }
        if byte == 0x22 { return index + 1 }
        index += 1
    }
    return bytes.count
}

// MARK: - Zustandsmaschine

private final class Exporter {
    private let bytes: [UInt8]
    private let store: TypstAssetStore
    private let sink: TypstByteSink
    private let syntax: TypstInlineImageSyntax

    private var buffer: [UInt8] = []
    private let bufferLimit = 16 * 1024

    init(source: String, store: TypstAssetStore, sink: TypstByteSink, syntax: TypstInlineImageSyntax) {
        self.bytes = Array(source.utf8)
        self.store = store
        self.sink = sink
        self.syntax = syntax
    }

    func run() throws -> Int {
        let source = String(decoding: bytes, as: UTF8.self)
        let hasAssets = !TypstDocumentExporter.assetReferences(in: source).isEmpty
        let hasImport = source.contains(syntax.decodeImportMarker)

        if hasAssets && !hasImport {
            try emit(Array((syntax.decodeImport + "\n").utf8))
        }

        var inlined = 0
        var index = 0

        while index < bytes.count {
            let byte = bytes[index]

            if byte == 0x22 { // '"'
                if let (ref, end) = parseAssetLiteral(bytes, from: index) {
                    try emit(Array((syntax.decodeFunction + "(").utf8))
                    try emitBase64Literal(for: ref)
                    try emit([0x29]) // ')'
                    inlined += 1
                    index = end
                    continue
                }
                let end = skipLiteral(bytes, from: index)
                try emit(Array(bytes[index..<end]))
                index = end
                continue
            }

            buffer.append(byte)
            index += 1
            try flushIfNeeded()
        }

        try flush()
        return inlined
    }

    // MARK: Ausgabe

    private func emit(_ chunk: [UInt8]) throws {
        buffer.append(contentsOf: chunk)
        try flushIfNeeded()
    }

    private func flushIfNeeded() throws {
        guard buffer.count >= bufferLimit else { return }
        try flush()
    }

    private func flush() throws {
        guard !buffer.isEmpty else { return }
        try sink.write(buffer[...])
        buffer.removeAll(keepingCapacity: true)
    }

    /// Schreibt `"<base64>"` und streamt die Bilddatei dabei chunkweise.
    private func emitBase64Literal(for ref: TypstAssetRef) throws {
        try flush()
        try sink.write([0x22])

        let source = try store.byteSource(for: ref)
        var encoder = Base64StreamEncoder()
        var input: [UInt8] = []
        var output: [UInt8] = []
        var offset = 0

        while true {
            let read = try source.read(at: offset, into: &input, maxLength: 48 * 1024)
            guard read > 0 else { break }
            offset += read
            output.removeAll(keepingCapacity: true)
            encoder.push(input[0..<read], into: &output)
            try sink.write(output[...])
        }

        output.removeAll(keepingCapacity: true)
        encoder.finish(into: &output)
        try sink.write(output[...])
        try sink.write([0x22])
    }
}
