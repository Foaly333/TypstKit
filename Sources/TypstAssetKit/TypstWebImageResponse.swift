//
//  TypstWebImageResponse.swift
//  TypstAssetKit
//
//  Entscheidet, ob eine geladene Web-Ressource als Bild uebernommen wird —
//  und unter welchem virtuellen Pfad.
//
//  Hintergrund: Der Scanner liefert *Kandidaten*. Ein `#let host = "https://…"`
//  im Dokument ist ein legitimes Literal und wird als Kandidat gemeldet. Wenn
//  der Verbraucher jede 2xx-Antwort als Bild akzeptiert, wird die HTML-Startseite
//  eines Servers zum „Bild" — mit allen Folgen fuer den Quelltext. Die Haerte
//  gehoert deshalb hierher, nicht in die Regex.
//
//  Die Pruefung ist bewusst reine Textverarbeitung: kein Netz, keine
//  Rust-Binary, damit sie in `TypstAssetKitTests` vollstaendig testbar ist.
//

import Foundation

public enum TypstWebImageResponse {

    /// Praefix, unter dem geladene Web-Bilder im virtuellen Dateisystem des
    /// Compilers liegen.
    public static let virtualPrefix = "__web__"

    /// Prueft eine geladene Web-Ressource und liefert den virtuellen Pfad,
    /// unter dem sie dem Compiler uebergeben wird — oder `nil`, wenn sie kein
    /// Bild ist. `nil` ist **kein Fehler**: ein Kandidat, der keine Bild-URL
    /// war, soll wirkungslos bleiben und keine Diagnostik erzeugen.
    ///
    /// - Parameters:
    ///   - urlString: die angefragte URL, so wie sie im Quelltext steht
    ///   - contentType: der `Content-Type`-Header der Antwort, falls vorhanden
    ///   - data: der Antwortkoerper
    public static func imagePath(
        forURL urlString: String,
        contentType: String?,
        data: some Collection<UInt8>
    ) -> String? {
        guard let url = URL(string: urlString) else { return nil }

        // S5: Eine URL ohne Pfadanteil (blosser Host) kann kein Bild sein.
        guard hasPath(url) else { return nil }

        let mime = contentType?
            .split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespaces)
            .lowercased()

        // Ausgeliefertes HTML ist nie ein Bild — egal, wie der Koerper anfaengt.
        if let mime, mime.hasPrefix("text/html") || mime.hasPrefix("application/xhtml") {
            return nil
        }

        // Inhalt anhand der Magic Bytes pruefen — nicht anhand der URL-Endung,
        // die luegen kann.
        guard let format = TypstImageFormat.sniff(data) else { return nil }

        // `sniff` erkennt SVG daran, dass das erste Zeichen `<` ist — das trifft
        // auf jede HTML-Seite ebenso zu. Fuer den SVG-Fall braucht es deshalb
        // eine zweite Bestaetigung: entweder ein `image/`-Content-Type oder ein
        // `<svg`-Tag am Anfang des Dokuments.
        if format == .svg, !confirmsSVG(data, mime: mime) { return nil }

        return "\(virtualPrefix)/\(filename(for: url, urlString: urlString, format: format))"
    }

    /// Hat die URL ueberhaupt einen Pfadanteil? `https://host` und `https://host/`
    /// haben keinen — sie koennen nie auf ein Bild zeigen.
    public static func hasPath(_ url: URL) -> Bool {
        let path = url.path(percentEncoded: false)
        return !path.isEmpty && path != "/"
    }

    // MARK: - Intern

    /// Dateiname im virtuellen Dateisystem: der letzte Pfadbestandteil, ergaenzt
    /// um die tatsaechlich erkannte Endung.
    private static func filename(
        for url: URL,
        urlString: String,
        format: TypstImageFormat
    ) -> String {
        let last = url.lastPathComponent
        // Trailing Slash (`https://host/verzeichnis/`) kann einen leeren oder
        // unbrauchbaren letzten Bestandteil liefern — dann ein stabiler Name.
        let base = (last.isEmpty || last == "/" || last == ".")
            ? "image_\(stableHash(urlString))"
            : last

        let components = base.split(separator: ".", omittingEmptySubsequences: false)
        if components.count > 1,
           let existing = TypstImageFormat.from(fileExtension: String(components[components.count - 1])),
           existing == format {
            return base
        }
        return "\(base).\(format.fileExtension)"
    }

    /// Bestaetigt, dass ein mit `<` beginnendes Dokument wirklich SVG ist.
    private static func confirmsSVG(_ data: some Collection<UInt8>, mime: String?) -> Bool {
        if let mime, mime.hasPrefix("image/") { return true }

        // Nach `<svg` im Kopf des Dokuments suchen (XML-Deklaration, DOCTYPE und
        // Kommentare koennen davor stehen).
        let head = Array(data.prefix(4096)).map { byte -> UInt8 in
            (byte >= 0x41 && byte <= 0x5A) ? byte + 0x20 : byte   // ASCII-lowercase
        }
        let needle = Array("<svg".utf8)
        guard head.count >= needle.count else { return false }
        for start in 0...(head.count - needle.count) where Array(head[start..<start + needle.count]) == needle {
            return true
        }
        return false
    }

    /// Ueber Prozessgrenzen hinweg stabiler Hash (FNV-1a, 64 Bit).
    /// `String.hashValue` ist pro Prozess randomisiert und taugt nicht fuer
    /// Dateinamen, die reproduzierbar sein sollen.
    private static func stableHash(_ string: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return String(hash, radix: 16)
    }
}
