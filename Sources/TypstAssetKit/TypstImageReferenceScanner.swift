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
//  (`TypstImageResolver` filtert auf `http(s)://` bzw. das lokale Praefix und
//  nimmt eine Web-Ressource nur an, wenn die Antwort tatsaechlich ein Bild ist).
//  Ein `#let titel = "Kapitel 1"` wird also erfasst, sofort verworfen und
//  kostet nichts. Der Scanner muss den Typst-Wertebereich nicht kennen.
//
//  Wichtig: Jeder Treffer traegt die **Range seines Literals** im Quelltext.
//  Nur ueber diese Range darf spaeter umgeschrieben werden. Ein textuelles
//  Suchen-und-Ersetzen kennt den Unterschied zwischen Code und Fliesstext
//  nicht und zerstoert Links, die zufaellig dieselbe Zeichenfolge enthalten.
//

import Foundation

/// Ein Bildpfad-Kandidat samt seiner Fundstelle im Quelltext.
public struct TypstImageReference: Sendable, Hashable {
    /// Der Inhalt des Literals — ohne Anfuehrungszeichen.
    public let path: String

    /// Bereich des Literals im Quelltext, **ohne** die Anfuehrungszeichen.
    public let range: Range<String.Index>

    public init(path: String, range: Range<String.Index>) {
        self.path = path
        self.range = range
    }
}

public enum TypstImageReferenceScanner {

    /// Pfad direkt im Aufruf: `image("…")` — einfache und doppelte Anfuehrungszeichen.
    ///
    /// Die fuehrende Zeichenklasse begrenzt den Funktionsnamen nach vorn: ohne sie
    /// matchen auch `qrimage("…")`, `myimage("…")` und `foo.image("…")`. Der Punkt
    /// gehoert mit in die Ausschlussklasse, damit Methodenaufrufe auf fremden
    /// Objekten nicht mitgehen. `#image(` und `image(` am Ausdrucksanfang bleiben
    /// Treffer, weil `#`, Leerzeichen und Zeilenanfang die Klasse erfuellen.
    ///
    /// Bewusst als konsumierende Alternative (`(?:^|[^…])`) statt als Lookbehind
    /// geschrieben — dieselbe Technik wie bei `letBindingPattern`.
    nonisolated(unsafe) private static let imageCallPattern =
        #/(?m)(?:^|[^\p{L}\p{N}_.])image\(\s*["']([^"']+)["']\s*(?:,|\))/#

    /// Pfad ueber eine Zuweisung: `#let name = "…"` (auch ohne `#`, im Code-Block).
    ///
    /// Die fuehrende Zeichenklasse verhindert, dass `let` als Wortende matcht
    /// (`#let outlet = "…"` liefert genau einen Treffer, nicht zwei).
    ///
    /// Die Laengenbegrenzung haelt noch nicht importierte Base64-Blobs draussen:
    /// ein Bild-Literal ist zehntausende Zeichen lang, ein Pfad nie.
    nonisolated(unsafe) private static let letBindingPattern =
        #/(?m)(?:^|[^\p{L}\p{N}_])#?let\s+[\p{L}_][\p{L}\p{N}_\-]*\s*=\s*"([^"\n]{1,512})"/#

    /// Alle Fundstellen von Pfad-Kandidaten, sortiert nach Position im Quelltext.
    ///
    /// **Nicht** ueber den Pfad dedupliziert: derselbe Pfad kann in `#let` *und*
    /// in `image("…")` stehen — beides ist Code, beide Literale sollen
    /// umgeschrieben werden. Dedupliziert wird nur ueber die Fundstelle selbst,
    /// falls beide Muster dasselbe Literal treffen.
    public static func scan(_ source: String) -> [TypstImageReference] {
        var seen = Set<Range<String.Index>>()
        var result: [TypstImageReference] = []

        func collect(_ capture: Substring) {
            let range = capture.startIndex..<capture.endIndex
            guard seen.insert(range).inserted else { return }
            result.append(TypstImageReference(path: String(capture), range: range))
        }

        for match in source.matches(of: imageCallPattern) {
            collect(match.output.1)
        }
        for match in source.matches(of: letBindingPattern) {
            collect(match.output.1)
        }

        return result.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    /// Alle Pfad-Kandidaten in Reihenfolge ihres Auftretens, dedupliziert.
    ///
    /// Bleibt als API bestehen; wer umschreiben will, braucht `scan(_:)`.
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
