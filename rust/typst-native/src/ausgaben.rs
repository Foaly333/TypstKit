//! Extraktion der Output-Flags (Flag-Kontrakt v1) aus einem kompilierten
//! Dokument.
//!
//! Dokumente melden Elemente ueber `#metadata((typ: …, daten: …))<mo-element>`
//! (mo-tools: `mo-melde`). Diese Meldungen werden hier im selben Kompilierlauf
//! ueber den Introspector eingesammelt und als JSON-Array serialisiert:
//!
//! `[{"typ": "timer", "daten": {…}, "seite": 0, "x_pt": 412.3, "y_pt": 88.0}]`
//!
//! - `seite` ist 0-basiert (Introspector liefert 1-basiert!)
//! - Koordinaten in pt, Ursprung oben links der Seite (Ankerpunkt)

use serde_json::{json, Value as Json};
use typst::foundations::{Label, Selector, Value};
use typst::introspection::MetadataElem;
use typst::layout::PagedDocument;
use typst::utils::PicoStr;

/// Label, unter dem der Flag-Kontrakt Meldungen ablegt.
const MO_LABEL: &str = "mo-element";

/// Sammelt alle `<mo-element>`-Meldungen des Dokuments und serialisiert sie
/// als JSON-Array (Flag-Kontrakt v1).
pub fn extrahiere_ausgaben(document: &PagedDocument) -> String {
    let selector = Selector::Label(Label::new(PicoStr::intern(MO_LABEL)));
    let mut objekte: Vec<Json> = Vec::new();

    for elem in document.introspector.query(&selector) {
        // Nur metadata-Elemente sind Teil des Kontrakts.
        let Some(meta) = elem.to_packed::<MetadataElem>() else {
            continue;
        };
        let Some(location) = elem.location() else {
            continue;
        };
        let pos = document.introspector.position(location);

        // Gemeldetes Dictionary (typ: …, daten: …) nach JSON abbilden.
        let wert = value_zu_json(&meta.value);
        let (typ, daten) = match &wert {
            Json::Object(map) => (
                map.get("typ").cloned().unwrap_or(Json::Null),
                map.get("daten").cloned().unwrap_or(Json::Null),
            ),
            // Meldung ohne Dictionary-Struktur: Rohwert als daten durchreichen.
            _ => (Json::Null, wert.clone()),
        };

        objekte.push(json!({
            "typ": typ,
            "daten": daten,
            // pos.page ist 1-basiert (NonZeroUsize) → 0-basiert normalisieren.
            "seite": pos.page.get() - 1,
            "x_pt": pos.point.x.to_pt(),
            "y_pt": pos.point.y.to_pt(),
        }));
    }

    serde_json::to_string(&objekte).unwrap_or_else(|_| "[]".to_string())
}

/// Bildet einen Typst-Wert auf JSON ab.
///
/// Kontrakt: nur Str/Int/Float/Bool/None/Array/Dict sind erlaubt. Alles
/// andere (Content, Length, Func, …) wird zu JSON-null und im Debug-Log
/// vermerkt — die Payload bleibt dadurch stabil dekodierbar.
fn value_zu_json(value: &Value) -> Json {
    match value {
        Value::None => Json::Null,
        Value::Bool(b) => Json::Bool(*b),
        Value::Int(i) => json!(i),
        Value::Float(f) => json!(f),
        Value::Str(s) => Json::String(s.as_str().to_string()),
        Value::Array(a) => Json::Array(a.iter().map(value_zu_json).collect()),
        Value::Dict(d) => Json::Object(
            d.iter()
                .map(|(k, v)| (k.as_str().to_string(), value_zu_json(v)))
                .collect(),
        ),
        other => {
            #[cfg(debug_assertions)]
            eprintln!(
                "mo-element: Payload-Wert vom Typ {} ist nicht JSON-faehig → null",
                other.ty()
            );
            let _ = other;
            Json::Null
        }
    }
}
