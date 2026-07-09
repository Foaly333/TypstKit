//
//  TypstImageReferenceScanner.swift
//  TypstAssetKit
//
//  Findet Bildpfad-Kandidaten in einem Typst-Quelltext.
//
//  Zwei Formen kommen vor:
//
//    1. Der Pfad steht direkt im Aufruf:
//         #image("img/foto.png")
//
//    2. Der Pfad ist an einen Bezeichner gebunden:
//         #let fotoCode = "img/foto.png"
//         #let foto     = image(fotoCode)
//
//  Form 2 ist die kanonische Ausgabe von `TypstDocumentImporter` (Form A):
//  Er schreibt `#let x = "<base64>"` zu `#let x = "img/…"` um und entfernt den
//  `base64.decode(…)`-Aufruf, sodass aus `image(base64.decode(x))` ein blosses
//  `image(x)` wird. Der Pfad taucht danach in keinem `image(...)` mehr auf.
//
//  Der Scanner liefert bewusst *Kandidaten*, keine gesicherten Bildpfade.
//  Ob ein Kandidat ueberhaupt geladen wird, entscheidet der Aufrufer
//  (`TypstImageResolver` filtert auf `http(s)://` bzw. das lokale Praefix).
//  Ein `#let titel = "Kapitel 1"` wird also erfasst, sofort verworfen und
//  kostet nichts. Der Scanner muss den Typst-Wertebereich nicht kennen.
//

import Foundation

public enum TypstImageReferenceScanner {

    /// Pfad direkt im Aufruf: `image("…")` — einfache und doppelte Anfuehrungszeichen.
    nonisolated(unsafe) private static let imageCallPattern =
        #/image\(\s*["']([^"']+)["']\s*(?:,|\))/#

    /// Pfad ueber eine Zuweisung: `#let name = "…"` (auch ohne `#`, im Code-Block).
    ///
    /// Die fuehrende Zeichenklasse verhindert, dass `let` als Wortende matcht
    /// (`#let outlet = "…"` liefert genau einen Treffer, nicht zwei).
    ///
    /// Die Laengenbegrenzung haelt noch nicht importierte Base64-Blobs draussen:
    /// ein Bild-Literal ist zehntausende Zeichen lang, ein Pfad nie.
    nonisolated(unsafe) private static let letBindingPattern =
        #/(?m)(?:^|[^\p{L}\p{N}_])#?let\s+[\p{L}_][\p{L}\p{N}_\-]*\s*=\s*"([^"\n]{1,512})"/#

    /// Alle Pfad-Kandidaten in Reihenfolge ihres Auftretens, dedupliziert.
    public static func references(in source: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []

        func collect(_ path: String) {
            if seen.insert(path).inserted {
                result.append(path)
            }
        }

        for match in source.matches(of: imageCallPattern) {
            collect(String(match.output.1))
        }
        for match in source.matches(of: letBindingPattern) {
            collect(String(match.output.1))
        }

        return result
    }
}
