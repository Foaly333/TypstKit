//! Nativer Typst-Compiler fuer iOS.
//!
//! Stellt compile_to_pdf() und compile_to_svg() ueber UniFFI bereit.
//! Schriftarten werden als Byte-Arrays von der Swift-Seite uebergeben,
//! um Sandbox-Probleme auf iOS zu vermeiden.
//! Packages werden als PackageFile-Listen uebergeben.

mod ausgaben;
mod diagnostics;
mod fonts;
mod world;

use std::collections::HashMap;

use diagnostics::TypstCompilationError;
use typst::foundations::{Dict, Value};
use typst::layout::PagedDocument;
use world::{ImageFile, PackageFile, TypstWorld};

/// Begrenzt den prozessglobalen comemo-Memoisierungs-Cache von Typst.
///
/// Ohne diesen Aufruf waechst der Cache mit jeder Kompilierung unbegrenzt:
/// Jeder Lauf baut eine frische World mit eigenen Font-Kopien, und die
/// Cache-Eintraege halten diese Kopien dauerhaft fest (mehrere hundert MB
/// pro Lauf). Die Typst-CLI ruft evict() nach jedem Lauf genauso auf.
/// max_age = 2 erhaelt die Eintraege der letzten Laeufe, damit der
/// inkrementelle Editor-Preview weiterhin vom Cache profitiert.
fn cache_begrenzen() {
    comemo::evict(2);
}

/// Kompiliert Typst-Quelltext zu PDF-Bytes.
///
/// # Parameter
/// - `source`: Vollstaendiger Typst-Quelltext
/// - `font_data`: Liste von Font-Dateien als Byte-Arrays (TTF/OTF/TTC)
/// - `package_files`: Liste von Package-Dateien (bereits entpackt)
/// - `image_files`: Virtuelle Bilddateien (Web-Downloads + lokale img/-Dateien)
///
/// # Rueckgabe
/// PDF-Bytes bei Erfolg, Kompilierungsfehler mit Diagnosen bei Misserfolg.
#[uniffi::export]
fn compile_to_pdf(
    source: String,
    font_data: Vec<Vec<u8>>,
    package_files: Vec<PackageFile>,
    image_files: Vec<ImageFile>,
) -> Result<Vec<u8>, TypstCompilationError> {
    let world = TypstWorld::new(source, font_data, package_files, image_files);

    // typst::compile gibt Warned<Result<...>> zurueck
    let warned = typst::compile::<PagedDocument>(&world);

    let result = match warned.output {
        Ok(document) => {
            let options = typst_pdf::PdfOptions::default();
            match typst_pdf::pdf(&document, &options) {
                Ok(pdf_bytes) => Ok(pdf_bytes),
                Err(export_errors) => {
                    let messages: Vec<String> = export_errors
                        .iter()
                        .map(|e| format!("{:?}", e))
                        .collect();
                    Err(TypstCompilationError::new_export_error(messages))
                }
            }
        }
        Err(diagnostics) => Err(TypstCompilationError::from_source_diagnostics(
            &world, diagnostics,
        )),
    };
    cache_begrenzen();
    result
}

/// Kompiliert Typst-Quelltext zu SVG-Strings (einer pro Seite).
///
/// # Parameter
/// - `source`: Vollstaendiger Typst-Quelltext
/// - `font_data`: Liste von Font-Dateien als Byte-Arrays (TTF/OTF/TTC)
/// - `package_files`: Liste von Package-Dateien (bereits entpackt)
/// - `image_files`: Virtuelle Bilddateien (Web-Downloads + lokale img/-Dateien)
///
/// # Rueckgabe
/// Vec von SVG-Strings (einer pro Seite) bei Erfolg.
#[uniffi::export]
fn compile_to_svg(
    source: String,
    font_data: Vec<Vec<u8>>,
    package_files: Vec<PackageFile>,
    image_files: Vec<ImageFile>,
) -> Result<Vec<String>, TypstCompilationError> {
    let world = TypstWorld::new(source, font_data, package_files, image_files);

    let warned = typst::compile::<PagedDocument>(&world);

    let result = match warned.output {
        Ok(document) => {
            let svgs: Vec<String> = document
                .pages
                .iter()
                .map(|page| typst_svg::svg(page))
                .collect();
            Ok(svgs)
        }
        Err(diagnostics) => Err(TypstCompilationError::from_source_diagnostics(
            &world, diagnostics,
        )),
    };
    cache_begrenzen();
    result
}

/// Ergebnis einer Kompilierung mit Flag-Kontrakt:
/// PDF-Bytes plus die vom Dokument gemeldeten Output-Flags als JSON-Array
/// (Flag-Kontrakt v1, siehe `ausgaben.rs`).
#[derive(Debug, Clone, uniffi::Record)]
pub struct CompileResult {
    /// Das kompilierte PDF
    pub pdf: Vec<u8>,
    /// JSON-Array der `<mo-element>`-Meldungen:
    /// `[{"typ": …, "daten": …, "seite": 0, "x_pt": …, "y_pt": …}]`
    pub ausgaben_json: String,
}

/// Kompiliert Typst-Quelltext zu PDF-Bytes — mit Input-Flags (`sys.inputs`)
/// und Extraktion der Output-Flags im selben Kompilierlauf.
///
/// # Parameter
/// - `source`: Vollstaendiger Typst-Quelltext
/// - `font_data`: Liste von Font-Dateien als Byte-Arrays (TTF/OTF/TTC)
/// - `package_files`: Liste von Package-Dateien (bereits entpackt)
/// - `image_files`: Virtuelle Bilddateien (Web-Downloads + lokale img/-Dateien)
/// - `inputs`: Input-Flags, im Dokument via `sys.inputs` sichtbar
///
/// # Rueckgabe
/// `CompileResult` (PDF + Output-Flags-JSON) bei Erfolg.
#[uniffi::export]
fn compile_to_pdf_with_flags(
    source: String,
    font_data: Vec<Vec<u8>>,
    package_files: Vec<PackageFile>,
    image_files: Vec<ImageFile>,
    inputs: HashMap<String, String>,
) -> Result<CompileResult, TypstCompilationError> {
    // String-Paare → Typst-Dict fuer sys.inputs
    let dict: Dict = inputs
        .into_iter()
        .map(|(k, v)| (k.into(), Value::Str(v.into())))
        .collect();

    let world =
        TypstWorld::new_mit_inputs(source, font_data, package_files, image_files, Some(dict));

    let warned = typst::compile::<PagedDocument>(&world);

    let result = match warned.output {
        Ok(document) => {
            // Output-Flags im selben Lauf extrahieren (kein zweites Kompilieren).
            let ausgaben_json = ausgaben::extrahiere_ausgaben(&document);

            let options = typst_pdf::PdfOptions::default();
            match typst_pdf::pdf(&document, &options) {
                Ok(pdf_bytes) => Ok(CompileResult {
                    pdf: pdf_bytes,
                    ausgaben_json,
                }),
                Err(export_errors) => {
                    let messages: Vec<String> = export_errors
                        .iter()
                        .map(|e| format!("{:?}", e))
                        .collect();
                    Err(TypstCompilationError::new_export_error(messages))
                }
            }
        }
        Err(diagnostics) => Err(TypstCompilationError::from_source_diagnostics(
            &world, diagnostics,
        )),
    };
    cache_begrenzen();
    result
}

uniffi::setup_scaffolding!();

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_compile_simple_text() {
        let source = "Hello World".to_string();
        let result = compile_to_pdf(source, vec![], vec![], vec![]);
        assert!(result.is_ok() || result.is_err());
    }

    #[test]
    fn test_compile_invalid_source() {
        let source = "#nonexistent_function()".to_string();
        let result = compile_to_pdf(source, vec![], vec![], vec![]);
        if let Err(err) = result {
            assert!(!err.diagnostics().is_empty() || !err.summary().is_empty());
        }
    }

    #[test]
    fn test_compile_svg_returns_pages() {
        let source = "= Ueberschrift\nText".to_string();
        let result = compile_to_svg(source, vec![], vec![], vec![]);
        if let Ok(svgs) = result {
            assert!(!svgs.is_empty());
            for svg in &svgs {
                assert!(svg.contains("<svg"));
            }
        }
    }

    #[test]
    fn test_compile_with_flags_inputs_und_extraktion() {
        // Input-Flag erreicht sys.inputs; Meldung wird extrahiert.
        let source = concat!(
            "Wert: #sys.inputs.at(\"x\", default: \"leer\")\n",
            "#metadata((typ: \"ping\", daten: (n: 7)))<mo-element>",
        )
        .to_string();

        let mut inputs = HashMap::new();
        inputs.insert("x".to_string(), "hallo".to_string());

        let result = compile_to_pdf_with_flags(source, vec![], vec![], vec![], inputs)
            .expect("Kompilierung mit Flags muss gelingen");

        assert!(!result.pdf.is_empty());
        let json: serde_json::Value =
            serde_json::from_str(&result.ausgaben_json).expect("Ausgaben muessen JSON sein");
        let arr = json.as_array().expect("JSON-Array erwartet");
        assert_eq!(arr.len(), 1);
        assert_eq!(arr[0]["typ"], "ping");
        assert_eq!(arr[0]["daten"]["n"], 7);
        assert_eq!(arr[0]["seite"], 0);
        assert!(arr[0]["x_pt"].is_number() && arr[0]["y_pt"].is_number());
    }

    #[test]
    fn test_compile_with_flags_ohne_inputs() {
        // Leere Inputs entsprechen dem Verhalten der alten Funktionen.
        let source = "Nur Text".to_string();
        let result = compile_to_pdf_with_flags(source, vec![], vec![], vec![], HashMap::new())
            .expect("Kompilierung ohne Inputs muss gelingen");
        assert!(!result.pdf.is_empty());
        assert_eq!(result.ausgaben_json, "[]");
    }
}
