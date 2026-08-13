# mo-tools 0.1.0

Flag-Kontrakt zwischen Typst-Dokumenten und der MaterialOrganizer-App
(Kontrakt-Version 1).

## Kanäle

**Hinkanal — Input-Flags.** Die App (oder extern `typst compile --input k=v`)
übergibt String-Paare, die im Dokument über `sys.inputs` sichtbar sind.
`mo-eingabe`, `mo-gesetzt` und `mo-wenn` kapseln den Zugriff.

**Rückkanal — Output-Flags.** `mo-melde(typ, daten: …)` legt ein
`metadata`-Element unter dem Label `<mo-element>` ab. Die App extrahiert alle
Meldungen **im selben Kompilierlauf** (kein zweites Kompilieren) inklusive
Seite und Position. Extern liefert `typst query datei.typ "<mo-element>"`
dieselben Payloads.

## Reservierte Input-Schlüssel

Die App befüllt diese Schlüssel automatisch — eigene Flags dürfen die Namen
nicht verwenden:

`loesung`, `variante`, `kurs`, `datum`, `schuljahr`, `lehrkraft`

## JSON-Kontrakt der Ausgaben (Version 1)

Die App erhält je Meldung ein Objekt:

```json
[{"typ": "timer", "daten": {"minuten": 5}, "seite": 0, "x_pt": 412.3, "y_pt": 88.0}]
```

`seite` ist 0-basiert; `x_pt`/`y_pt` in pt, Ursprung oben links der Seite
(Ankerpunkt des Elements).

## Payload-Kontrakte der Standard-Anwendungen

| Makro | `typ` | `daten` |
|---|---|---|
| `mo-kann(flag)` | `kann` | `{flag: str}` |
| `mo-timer(minuten: 5)` | `timer` | `{minuten: int}` |
| `mo-quiz(frage:, antworten:, richtig:)` | `quiz` | `{frage: str, antworten: [str], richtig: int}` — `richtig` 1-basiert |
| `mo-kopien(klassensatz:, anzahl:)` | `kopien` | `{klassensatz: bool, anzahl: int \| null}` |
| `mo-hausaufgabe(text)` | `hausaufgabe` | `{text: str}` |
| `mo-variante(..)` | `kann` | `{flag: "variante", anzahl: int}` — Auswahl über Input-Flag `variante` (1-basiert, Modulo bei Überlauf) |
| `mo-aufdecken(inhalt)` | `aufdecken` | `{breite_pt: float, hoehe_pt: float}` |
| `mo-medium(titel:, url:, anhang:)` | `medium` | `{titel: str, url: str \| null, anhang: str \| null}` — genau eines von `url`/`anhang` setzen |
| `mo-punkte(punkte)` | `punkte` | `{punkte: int}` |
| `mo-dauer(minuten:, sichtbar:)` | `dauer` | `{minuten: int}` |

## Regeln

1. Payloads dürfen nur JSON-fähige Werte enthalten: `str`, `int`, `float`,
   `bool`, `none`, `array`, `dictionary` — **kein Content**. Nicht abbildbare
   Werte werden zu `null` und im Debug-Log vermerkt.
2. Quiz-Fragen und -Antworten sind Strings, kein Markup (JSON-Payload!).
3. Bool-Flags akzeptieren `ja`, `true`, `1` (Groß-/Kleinschreibung egal).
4. `mo-aufdecken` misst per `layout()` in der tatsächlichen Containerbreite
   (Blockinhalte mit relativer Breite kollabieren in einer unbegrenzten
   Messung) und ist deshalb block-level — nicht mitten in einen Absatz setzen.
5. Die App injiziert mo-tools **nicht** automatisch; das Paket wird pro
   Kompilierlauf explizit mitgegeben (`MoToolsPackage.files`) und mit
   `#import "@local/mo-tools:0.1.0": *` eingebunden.

## Externe Nutzung (Typst-CLI)

```bash
./install.sh
typst compile probe.typ probe-aufgabe.pdf
typst compile --input loesung=ja probe.typ probe-loesung.pdf
typst compile --input variante=2 probe.typ probe-b.pdf
typst query probe.typ "<mo-element>"
```
