// kontrakt.typ — die Primitive des Flag-Kontrakts (Version 1).
//
// Hinkanal:  Input-Flags via sys.inputs (extern: typst compile --input k=v,
//            in der App: kompiliereMitFlags(inputs:)).
// Rückkanal: Output-Flags via metadata unter dem Label <mo-element>,
//            von der App im selben Kompilierlauf extrahiert.

// ─── Hinkanal: Input-Flags (sys.inputs) ───────────────────────────────

/// Liest einen Input-Flag; `standard` greift, wenn der Schlüssel fehlt.
#let mo-eingabe(schluessel, standard: none) = sys.inputs.at(schluessel, default: standard)

/// Bool-Interpretation eines Flags: "ja", "true" und "1" gelten als gesetzt.
#let mo-gesetzt(flag) = lower(str(mo-eingabe(flag, standard: "nein"))) in ("ja", "true", "1")

/// Bedingter Inhalt: `inhalt` wenn Flag gesetzt, sonst `sonst`.
#let mo-wenn(flag, inhalt, sonst: none) = if mo-gesetzt(flag) { inhalt } else { sonst }

// ─── Rückkanal: Output-Flags (metadata + Label) ───────────────────────
// Payload-Werte müssen JSON-serialisierbar sein: str, int, float, bool,
// none, array, dictionary — KEIN content (siehe README).

/// Meldet ein Element an die App: Typ + JSON-fähige Daten.
#let mo-melde(typ, daten: (:)) = [#metadata((typ: typ, daten: daten))<mo-element>]

/// Meldet eine Fähigkeit des Dokuments (z. B. reagiert auf einen Flag).
#let mo-kann(flag) = mo-melde("kann", daten: (flag: flag))
