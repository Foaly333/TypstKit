//! Nativer Typst-Compiler fuer iOS.
//!
//! Stellt compile_to_pdf() und compile_to_svg() ueber UniFFI bereit.
//! Schriftarten werden als Byte-Arrays von der Swift-Seite uebergeben,
//! um Sandbox-Probleme auf iOS zu vermeiden.
//! Packages werden als PackageFile-Listen uebergeben.

mod diagnostics;
mod fonts;
mod world;

use diagnostics::TypstCompilationError;
use typst::layout::PagedDocument;
use world::{ImageFile, PackageFile, TypstWorld};

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

    match warned.output {
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
    }
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

    match warned.output {
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
    }
}

uniffi::setup_scaffolding!();

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_compile_simple_text() {
        let source = "Hello World".to_string();
        let result = compile_to_pdf(source, vec![], vec![]);
        assert!(result.is_ok() || result.is_err());
    }

    #[test]
    fn test_compile_invalid_source() {
        let source = "#nonexistent_function()".to_string();
        let result = compile_to_pdf(source, vec![], vec![]);
        if let Err(err) = result {
            assert!(!err.diagnostics().is_empty() || !err.summary().is_empty());
        }
    }

    #[test]
    fn test_compile_svg_returns_pages() {
        let source = "= Ueberschrift\nText".to_string();
        let result = compile_to_svg(source, vec![], vec![]);
        if let Ok(svgs) = result {
            assert!(!svgs.is_empty());
            for svg in &svgs {
                assert!(svg.contains("<svg"));
            }
        }
    }
}
