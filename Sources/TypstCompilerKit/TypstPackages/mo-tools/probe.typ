// probe.typ — Nativ-Probe für mo-tools (A6).
// Kompilieren:
//   ./install.sh
//   typst compile probe.typ probe-aufgabe.pdf
//   typst compile --input loesung=ja probe.typ probe-loesung.pdf
//   typst compile --input variante=2 probe.typ probe-b.pdf
//   typst query probe.typ "<mo-element>"

#import "@local/mo-tools:0.1.0": *

#set page(paper: "a4")
#set text(lang: "de")

#mo-kopien(klassensatz: true)
#mo-dauer(minuten: 20)

= Probeblatt mo-tools

#mo-wenn("loesung", [_Lösungsfassung_], sonst: [_Aufgabenfassung_])

== Aufgabe 1 #mo-punkte(4)

#mo-variante[
  Berechne $3 dot 7$.
][
  Berechne $4 dot 6$.
]

#mo-timer(minuten: 5)

== Aufgabe 2 #mo-punkte(2)

#mo-quiz(
  frage: "Was ist die Hauptstadt von Rheinland-Pfalz?",
  antworten: ("Koblenz", "Mainz", "Trier"),
  richtig: 2,
)

== Aufgabe 3

#mo-aufdecken[
  Dieser Abschnitt wird in der Präsentation schrittweise aufgedeckt.
]

#mo-medium(titel: "Erklärvideo", url: "https://example.org/video")

#mo-hausaufgabe("Buch S. 42, Aufgaben 1–3")
