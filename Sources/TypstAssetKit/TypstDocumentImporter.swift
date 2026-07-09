//
//  TypstDocumentImporter.swift
//  TypstAssetKit
//
//  Wandelt eingebettete Base64-Bilder in Store-Referenzen um.
//
//  Der Importer ist *streamend*: Ein 200-MB-Dokument wird mit ein paar
//  Kilobyte Arbeitsspeicher migriert. Die Base64-Zeichen wandern direkt vom
//  Lesepuffer in den Decoder und von dort in die Zieldatei; der Rohtext des
//  Blobs liegt nie am Stueck im Speicher.
//
//  Zentrale Invariante — *byte-preserving*:
//  Ausserhalb der erkannten Stellen gibt der Importer jedes Byte unveraendert
//  weiter. Kommentare, Whitespace, Escapes und kurze Strings bleiben exakt
//  erhalten. Wo etwas nicht sicher erkannt wird (kein Bildformat, ungueltiges
//  Base64), faellt er auf woertliches Kopieren zurueck.
//
//  Der Importer ist idempotent: ein bereits importiertes Dokument laeuft
//  unveraendert durch.
//

import Foundation

public enum TypstImportError: Error, Equatable {
    /// String-Literal ohne schliessendes Anfuehrungszeichen.
    case unterminatedString(offset: Int)
    /// `base64.decode("…")` ohne schliessende Klammer.
    case malformedDecodeCall(offset: Int)
}

public struct TypstImportSummary: Sendable {
    /// Alle Bilder, die das Ergebnis-Dokument referenziert — neu abgelegte
    /// *und* bereits vorhandene. Genau die Menge, die die Garbage Collection
    /// als „in Benutzung“ braucht.
    public let assets: [TypstAssetRef]
    /// Ob der Quelltext veraendert wurde. `false` heisst: nichts zu tun,
    /// das Dokument war schon importiert.
    public let didChange: Bool
}

public enum TypstDocumentImporter {

    // MARK: - Öffentliche API

    /// Importiert einen Quelltext, der bereits im Speicher liegt.
    public static func importSource(
        _ source: String,
        store: TypstAssetStore,
        syntax: TypstInlineImageSyntax = .default
    ) throws -> (source: String, summary: TypstImportSummary) {
        let sink = TypstDataByteSink()
        let summary = try rewrite(
            source: TypstDataByteSource(source),
            into: sink,
            store: store,
            syntax: syntax
        )
        return (sink.string, summary)
    }

    /// Importiert `inputURL` nach `outputURL`. Beide duerfen nicht identisch sein.
    @discardableResult
    public static func importFile(
        at inputURL: URL,
        to outputURL: URL,
        store: TypstAssetStore,
        syntax: TypstInlineImageSyntax = .default
    ) throws -> TypstImportSummary {
        let source = try TypstFileByteSource(url: inputURL)
        let sink = try TypstFileByteSink(url: outputURL)
        return try rewrite(source: source, into: sink, store: store, syntax: syntax)
    }

    /// Migriert eine Datei an Ort und Stelle.
    ///
    /// Reihenfolge: erst vollstaendig in eine Nachbardatei schreiben, dann —
    /// und nur bei Erfolg — atomar ersetzen. Schlaegt irgendetwas fehl, bleibt
    /// das Original unangetastet. Optional wird es zusaetzlich gesichert.
    @discardableResult
    public static func importFileInPlace(
        at url: URL,
        store: TypstAssetStore,
        syntax: TypstInlineImageSyntax = .default,
        backupDirectory: URL? = nil
    ) throws -> TypstImportSummary {
        let fm = FileManager.default
        let temporaryURL = fm.temporaryDirectory
            .appendingPathComponent("typst-import-\(UUID().uuidString).typ")

        let summary: TypstImportSummary
        do {
            summary = try importFile(at: url, to: temporaryURL, store: store, syntax: syntax)
        } catch {
            try? fm.removeItem(at: temporaryURL)
            throw error
        }

        guard summary.didChange else {
            try? fm.removeItem(at: temporaryURL)
            return summary
        }

        if let backupDirectory {
            try fm.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
            let backupURL = backupDirectory.appendingPathComponent(url.lastPathComponent)
            try? fm.removeItem(at: backupURL)
            try fm.copyItem(at: url, to: backupURL)
        }

        _ = try fm.replaceItemAt(url, withItemAt: temporaryURL)
        return summary
    }

    // MARK: - Kern

    /// Die eigentliche Zustandsmaschine.
    @discardableResult
    public static func rewrite(
        source: TypstByteSource,
        into sink: TypstByteSink,
        store: TypstAssetStore,
        syntax: TypstInlineImageSyntax = .default
    ) throws -> TypstImportSummary {
        let importer = Importer(source: source, sink: sink, store: store, syntax: syntax)
        let summary = try importer.run()
        try sink.finish()
        return summary
    }
}

// MARK: - Zustandsmaschine

private final class Importer {
    private let reader: ByteReader
    private let source: TypstByteSource
    private let sink: TypstByteSink
    private let store: TypstAssetStore
    private let syntax: TypstInlineImageSyntax
    private let decodeCallOpen: [UInt8]

    /// Noch nicht geschriebener Text. Dient als Rueckblick-Kontext
    /// (`#let x =`, `base64.decode(`) und ist auf `tailLimit` begrenzt.
    private var tail: [UInt8] = []
    private let tailLimit = 1024
    private let tailKeep = 256

    /// Namen, die nach dem Import einen Asset-Pfad halten.
    private var assetLetNames: Set<String> = []

    private var assets: [TypstAssetRef] = []
    private var didChange = false

    init(source: TypstByteSource, sink: TypstByteSink, store: TypstAssetStore, syntax: TypstInlineImageSyntax) {
        self.source = source
        self.reader = ByteReader(source)
        self.sink = sink
        self.store = store
        self.syntax = syntax
        self.decodeCallOpen = syntax.decodeCallOpen
    }

    func run() throws -> TypstImportSummary {
        while let byte = try reader.next() {
            if byte == 0x22 { // '"'
                try handleStringLiteral(openQuoteOffset: reader.offset - 1)
                continue
            }

            tail.append(byte)

            if byte == 0x28, tail.hasSuffix(decodeCallOpen) { // '('
                try unwrapDecodeCallOnAssetName()
            }

            try trimTail()
        }

        try sink.write(tail[...])
        tail.removeAll()

        return TypstImportSummary(assets: assets, didChange: didChange)
    }

    // MARK: Tail

    private func trimTail() throws {
        guard tail.count > tailLimit else { return }
        let flushCount = tail.count - tailKeep
        try sink.write(tail[0..<flushCount])
        tail.removeFirst(flushCount)
    }

    private func flushTail() throws {
        try sink.write(tail[...])
        tail.removeAll(keepingCapacity: true)
    }

    // MARK: Kontext am Tail-Ende

    /// Laenge des Suffixes `base64.decode(` — plus eventuell folgendem
    /// Leerraum —, das direkt vor der aktuellen Position steht.
    /// `0`, wenn hier kein decode-Aufruf geoeffnet wurde.
    private func decodeCallSuffixLength() -> Int {
        var end = tail.count
        while end > 0, isAnyWhitespace(tail[end - 1]) { end -= 1 }
        guard end >= decodeCallOpen.count else { return 0 }
        let start = end - decodeCallOpen.count
        guard Array(tail[start..<end]) == decodeCallOpen else { return 0 }
        return tail.count - start
    }

    // MARK: `base64.decode(name)` → `name`

    /// Wir stehen direkt hinter `base64.decode(`. Folgt ein Bezeichner, der
    /// nach dem Import bereits einen Pfad haelt, faellt der Aufruf weg.
    private func unwrapDecodeCallOnAssetName() throws {
        let resumeOffset = reader.offset

        var identifier: [UInt8] = []
        var closed = false
        var budget = 256

        while budget > 0 {
            budget -= 1
            guard let byte = try reader.next() else { break }
            if identifier.isEmpty {
                if isAnyWhitespace(byte) { continue }
                guard isIdentifierStart(byte) else { break }
                identifier.append(byte)
                continue
            }
            if isIdentifierByte(byte) {
                identifier.append(byte)
                continue
            }
            if isAnyWhitespace(byte) { continue }
            closed = (byte == 0x29) // ')'
            break
        }

        let name = String(decoding: identifier, as: UTF8.self)
        guard closed, !identifier.isEmpty, assetLetNames.contains(name) else {
            try reader.seek(to: resumeOffset)
            return
        }

        tail.removeLast(decodeCallOpen.count)
        tail.append(contentsOf: identifier)
        didChange = true
    }

    // MARK: String-Literale

    private func handleStringLiteral(openQuoteOffset: Int) throws {
        let decodeCallSuffix = decodeCallSuffixLength()
        let wrapped = decodeCallSuffix > 0
        let letName = wrapped ? nil : matchLetAssignmentSuffix(tail)

        // Bereits importiert? Dann nichts anfassen — das macht den Importer
        // idempotent, ohne sich auf das Scheitern der Formaterkennung zu verlassen.
        if let existing = try matchAssetPathLiteral() {
            tail.append(0x22)
            tail.append(contentsOf: Array(existing.path.utf8))
            tail.append(0x22)
            assets.append(existing)
            if let letName { assetLetNames.insert(letName) }
            try trimTail()
            return
        }

        // Probe: die ersten `minimumBase64Length` signifikanten Zeichen.
        var probe: [UInt8] = []
        probe.reserveCapacity(syntax.minimumBase64Length)
        var significant = 0
        var offender: UInt8?
        var closedEarly = false

        while significant < syntax.minimumBase64Length {
            guard let byte = try reader.next() else {
                // EOF innerhalb des Literals — woertlich ausgeben, fertig.
                tail.append(0x22)
                tail.append(contentsOf: probe)
                try trimTail()
                return
            }
            if byte == 0x22 {
                closedEarly = true
                break
            }
            guard Base64StreamDecoder.isBase64Byte(byte) else {
                offender = byte
                break
            }
            probe.append(byte)
            if Base64StreamDecoder.isSignificantBase64Byte(byte) { significant += 1 }
        }

        // Zu kurz: das ganze Literal bleibt, wie es ist.
        if closedEarly {
            tail.append(0x22)
            tail.append(contentsOf: probe)
            tail.append(0x22)
            try trimTail()
            return
        }

        // Kein Base64: ab hier woertlich bis zum Ende des Literals.
        if let offender {
            tail.append(0x22)
            tail.append(contentsOf: probe)
            tail.append(offender)
            if offender == 0x5C, let escaped = try reader.next() { // '\'
                tail.append(escaped)
            }
            try copyLiteralBody(openQuoteOffset: openQuoteOffset)
            return
        }

        // Ab hier gilt das Literal als Bilddaten.
        try consumeBlob(
            probe: probe,
            openQuoteOffset: openQuoteOffset,
            decodeCallSuffix: decodeCallSuffix,
            letName: letName
        )
    }

    /// Prueft, ob das Literal ab der aktuellen Position ein Store-Pfad ist.
    ///
    /// Bei Treffer steht der Reader hinter dem schliessenden Anfuehrungszeichen,
    /// sonst unveraendert vor dem Inhalt.
    private func matchAssetPathLiteral() throws -> TypstAssetRef? {
        let resumeOffset = reader.offset
        var bytes: [UInt8] = []

        while bytes.count <= 128 {
            guard let byte = try reader.next() else { break }
            if byte == 0x22 { // '"'
                let path = String(decoding: bytes, as: UTF8.self)
                if let ref = TypstAssetRef(path: path) { return ref }
                break
            }
            if byte == 0x5C { break } // Escapes kommen in Pfaden nicht vor
            bytes.append(byte)
        }

        try reader.seek(to: resumeOffset)
        return nil
    }

    /// Kopiert den Rest eines Literals woertlich, inklusive Escapes,
    /// bis zum schliessenden Anfuehrungszeichen.
    private func copyLiteralBody(openQuoteOffset: Int) throws {
        while let byte = try reader.next() {
            tail.append(byte)
            if byte == 0x5C { // '\'
                if let escaped = try reader.next() { tail.append(escaped) }
                try trimTail()
                continue
            }
            if byte == 0x22 { // '"'
                try trimTail()
                return
            }
            try trimTail()
        }
        throw TypstImportError.unterminatedString(offset: openQuoteOffset)
    }

    /// Dekodiert den Blob direkt in den Store.
    private func consumeBlob(
        probe: [UInt8],
        openQuoteOffset: Int,
        decodeCallSuffix: Int,
        letName: String?
    ) throws {
        let writer = try store.beginWrite()
        var ref: TypstAssetRef?

        do {
            var decoder = Base64StreamDecoder()
            var out: [UInt8] = []
            out.reserveCapacity(48 * 1024)

            for byte in probe {
                try decoder.push(byte, into: &out)
            }

            var closed = false
            while let byte = try reader.next() {
                if byte == 0x22 { // '"'
                    closed = true
                    break
                }
                guard Base64StreamDecoder.isBase64Byte(byte) else {
                    throw Base64StreamDecoder.Failure.invalidCharacter(byte)
                }
                try decoder.push(byte, into: &out)
                if out.count >= 32 * 1024 {
                    try writer.append(out)
                    out.removeAll(keepingCapacity: true)
                }
            }
            guard closed else { throw TypstImportError.unterminatedString(offset: openQuoteOffset) }

            try decoder.finish(into: &out)
            try writer.append(out)
            ref = try writer.commit()
        } catch let error as TypstImportError {
            writer.discard()
            throw error
        } catch {
            // Kein gueltiges Base64 oder kein bekanntes Bildformat:
            // Literal unveraendert uebernehmen.
            writer.discard()
            try reader.seek(to: openQuoteOffset)
            _ = try reader.next() // das oeffnende '"'
            tail.append(0x22)
            try copyLiteralBody(openQuoteOffset: openQuoteOffset)
            return
        }

        guard let ref else { return }

        if decodeCallSuffix > 0 {
            tail.removeLast(decodeCallSuffix)
        }
        try flushTail()

        if decodeCallSuffix > 0 {
            try swallowClosingParen(openQuoteOffset: openQuoteOffset)
        }

        tail.append(contentsOf: Array("\"\(ref.path)\"".utf8))
        if let letName {
            assetLetNames.insert(letName)
        }
        assets.append(ref)
        didChange = true
        try trimTail()
    }

    /// Nach `base64.decode("…")` muss die schliessende Klammer folgen.
    ///
    /// Fehlt sie, ist der Aufruf nicht das, wofuer wir ihn gehalten haben —
    /// dann lieber abbrechen als ein kaputtes Dokument schreiben.
    private func swallowClosingParen(openQuoteOffset: Int) throws {
        let resumeOffset = reader.offset
        while let byte = try reader.next() {
            if isAnyWhitespace(byte) { continue }
            if byte == 0x29 { return } // ')'
            break
        }
        try reader.seek(to: resumeOffset)
        throw TypstImportError.malformedDecodeCall(offset: openQuoteOffset)
    }
}
