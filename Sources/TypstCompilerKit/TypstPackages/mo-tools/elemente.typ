// elemente.typ — Standard-Anwendungen des Flag-Kontrakts.
// Alle Makros bauen auf den Primitiven aus kontrakt.typ auf.

#import "kontrakt.typ": *

/// Sichtbare Standard-Optik für Marker.
#let mo-badge(inhalt) = box(
  stroke: 0.6pt + luma(40%), inset: (x: 0.35em, y: 0.25em),
  radius: 0.25em, text(size: 0.85em, inhalt),
)

/// Timer: sichtbares Badge + Meldung an die App.
#let mo-timer(minuten: 5) = box[
  #mo-melde("timer", daten: (minuten: minuten))
  #mo-badge[⏱ #minuten min]
]

/// Quiz: frage/antworten als STRINGS (JSON-Payload!), richtig 1-basiert.
/// Nativ: Ankreuzliste; im Lösungsmodus ist die richtige Antwort markiert.
#let mo-quiz(frage: "", antworten: (), richtig: 1) = block(breakable: false)[
  #mo-melde("quiz", daten: (frage: frage, antworten: antworten, richtig: richtig))
  *#frage* \
  #for (i, a) in antworten.enumerate() [
    #box(width: 0.9em, height: 0.9em, stroke: 0.8pt, baseline: 15%)[
      #if mo-gesetzt("loesung") and i + 1 == richtig { align(center)[✗] }
    ] #a \
  ]
]

/// Kopienbedarf: unsichtbare Deklaration, typisch am Dokumentanfang.
#let mo-kopien(klassensatz: false, anzahl: none) = mo-melde(
  "kopien", daten: (klassensatz: klassensatz, anzahl: anzahl),
)

/// Hausaufgabe: sichtbar auf dem Blatt UND als Flag an die App (String!).
#let mo-hausaufgabe(text) = block[
  #mo-melde("hausaufgabe", daten: (text: text))
  #mo-badge[🏠 Hausaufgabe: #text]
]

/// Gleichwertige Aufgaben-Varianten; Input-Flag "variante" (1-basiert),
/// implizite Fähigkeits-Meldung, Modulo statt Fehler bei kürzeren Listen.
#let mo-variante(..varianten) = {
  let v = varianten.pos()
  mo-melde("kann", daten: (flag: "variante", anzahl: v.len()))
  let i = int(mo-eingabe("variante", standard: "1"))
  v.at(calc.rem(i - 1, v.len()))
}

/// Schrittweises Aufdecken: nativ sichtbar, Fläche wird in der Payload
/// mitgemeldet (Introspector liefert nur den Ankerpunkt).
#let mo-aufdecken(inhalt) = context {
  let s = measure(inhalt)
  box[
    #mo-melde("aufdecken", daten: (breite_pt: s.width.pt(), hoehe_pt: s.height.pt()))
    #inhalt
  ]
}

/// Medien-Sprungmarke: genau eines von url/anhang setzen.
#let mo-medium(titel: "", url: none, anhang: none) = box[
  #mo-melde("medium", daten: (titel: titel, url: url, anhang: anhang))
  #mo-badge[▶ #titel]
]

/// Punktzahl einer Aufgabe: sichtbares Badge + Meldung.
#let mo-punkte(punkte) = box[
  #mo-melde("punkte", daten: (punkte: punkte))
  #mo-badge[#punkte P.]
]

/// Zeitbedarf: Meldung an die App, optional sichtbar.
#let mo-dauer(minuten: 5, sichtbar: false) = {
  mo-melde("dauer", daten: (minuten: minuten))
  if sichtbar { mo-badge[⏱ ca. #minuten min] }
}
