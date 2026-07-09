//
//  ByteStreams.swift
//  TypstAssetKit
//
//  Minimale Byte-Abstraktion fuer den streamenden Import.
//
//  Ein Dokument mit eingebetteten Base64-Bildern kann Dutzende MB gross sein.
//  Der Importer darf es deshalb nie als `String` materialisieren. Alle Lese-
//  und Schreibpfade laufen ueber diese beiden Protokolle; der Speicherbedarf
//  ist durch die Chunk-Groesse begrenzt, nicht durch die Dokumentgroesse.
//
//  `TypstByteSource` ist bewusst *wahlfrei* (Lesen ab beliebigem Offset).
//  Der Importer braucht das, um beim Zurueckfallen auf woertliches Kopieren
//  an den Anfang eines String-Literals zurueckzuspringen.
//

import Foundation

// MARK: - Quelle

/// Wahlfrei lesbare Byte-Quelle.
public protocol TypstByteSource: AnyObject {
    /// Liest bis zu `maxLength` Bytes ab `offset`.
    /// `buffer` wird dabei komplett ersetzt.
    /// - Returns: Anzahl gelesener Bytes, 0 bedeutet EOF.
    func read(at offset: Int, into buffer: inout [UInt8], maxLength: Int) throws -> Int
}

/// Byte-Quelle auf einer Datei. Haelt ein `FileHandle` offen.
public final class TypstFileByteSource: TypstByteSource {
    private let handle: FileHandle

    public init(url: URL) throws {
        self.handle = try FileHandle(forReadingFrom: url)
    }

    deinit {
        try? handle.close()
    }

    public func read(at offset: Int, into buffer: inout [UInt8], maxLength: Int) throws -> Int {
        try handle.seek(toOffset: UInt64(offset))
        guard let data = try handle.read(upToCount: maxLength), !data.isEmpty else {
            buffer.removeAll(keepingCapacity: true)
            return 0
        }
        buffer.removeAll(keepingCapacity: true)
        buffer.append(contentsOf: data)
        return data.count
    }
}

/// Byte-Quelle auf einem Speicherpuffer. Vor allem fuer Tests und
/// fuer kurze Quelltexte, die ohnehin schon im Speicher liegen.
public final class TypstDataByteSource: TypstByteSource {
    private let bytes: [UInt8]

    public init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    public init(_ string: String) {
        self.bytes = Array(string.utf8)
    }

    public func read(at offset: Int, into buffer: inout [UInt8], maxLength: Int) throws -> Int {
        buffer.removeAll(keepingCapacity: true)
        guard offset < bytes.count else { return 0 }
        let end = min(bytes.count, offset + maxLength)
        buffer.append(contentsOf: bytes[offset..<end])
        return end - offset
    }
}

// MARK: - Senke

/// Sequentiell beschreibbare Byte-Senke.
public protocol TypstByteSink: AnyObject {
    func write(_ bytes: ArraySlice<UInt8>) throws
    /// Schreibt gepufferte Daten heraus. Muss am Ende genau einmal aufgerufen werden.
    func finish() throws
}

public extension TypstByteSink {
    func write(_ bytes: [UInt8]) throws {
        try write(bytes[...])
    }

    func write(_ string: String) throws {
        try write(Array(string.utf8)[...])
    }
}

/// Gepufferte Datei-Senke.
public final class TypstFileByteSink: TypstByteSink {
    private let handle: FileHandle
    private var buffer: [UInt8] = []
    private let bufferLimit: Int

    public init(url: URL, bufferLimit: Int = 64 * 1024) throws {
        let fm = FileManager.default
        let parent = url.deletingLastPathComponent()
        if !fm.fileExists(atPath: parent.path) {
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        fm.createFile(atPath: url.path, contents: nil)
        self.handle = try FileHandle(forWritingTo: url)
        self.bufferLimit = bufferLimit
        self.buffer.reserveCapacity(bufferLimit)
    }

    public func write(_ bytes: ArraySlice<UInt8>) throws {
        buffer.append(contentsOf: bytes)
        if buffer.count >= bufferLimit {
            try flush()
        }
    }

    public func finish() throws {
        try flush()
        try handle.close()
    }

    private func flush() throws {
        guard !buffer.isEmpty else { return }
        try handle.write(contentsOf: Data(buffer))
        buffer.removeAll(keepingCapacity: true)
    }
}

/// Senke in den Speicher. Fuer Tests und fuer das Erzeugen von Strings
/// (z.B. „Quelltext in die Zwischenablage kopieren“).
public final class TypstDataByteSink: TypstByteSink {
    public private(set) var bytes: [UInt8] = []

    public init() {}

    public func write(_ bytes: ArraySlice<UInt8>) throws {
        self.bytes.append(contentsOf: bytes)
    }

    public func finish() throws {}

    public var string: String {
        String(decoding: bytes, as: UTF8.self)
    }
}

// MARK: - Reader

/// Gepufferter, vorwaertslesender Reader mit Ruecksprungmoeglichkeit.
///
/// `offset` ist stets die absolute Position des naechsten Bytes.
/// `seek(to:)` bleibt innerhalb des aktuellen Chunks allokationsfrei.
final class ByteReader {
    private let source: TypstByteSource
    private let chunkSize: Int
    private var chunk: [UInt8] = []
    private var chunkStart = 0
    private var index = 0
    private var reachedEnd = false

    init(_ source: TypstByteSource, chunkSize: Int = 64 * 1024) {
        self.source = source
        self.chunkSize = chunkSize
    }

    /// Absolute Position des naechsten zu lesenden Bytes.
    var offset: Int { chunkStart + index }

    func next() throws -> UInt8? {
        if index == chunk.count {
            if reachedEnd { return nil }
            try refill()
            if chunk.isEmpty {
                reachedEnd = true
                return nil
            }
        }
        let byte = chunk[index]
        index += 1
        return byte
    }

    func seek(to newOffset: Int) throws {
        if newOffset >= chunkStart && newOffset <= chunkStart + chunk.count {
            index = newOffset - chunkStart
            reachedEnd = false
            return
        }
        chunkStart = newOffset
        chunk.removeAll(keepingCapacity: true)
        index = 0
        reachedEnd = false
    }

    private func refill() throws {
        chunkStart += chunk.count
        index = 0
        let read = try source.read(at: chunkStart, into: &chunk, maxLength: chunkSize)
        if read == 0 {
            chunk.removeAll(keepingCapacity: true)
        }
    }
}
