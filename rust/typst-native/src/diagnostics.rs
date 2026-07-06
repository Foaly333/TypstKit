//! Fehler- und Diagnosetypen fuer die FFI-Schnittstelle.
//!
//! Bildet Typst-Compiler-Diagnosen auf UniFFI-kompatible Typen ab,
//! die in Swift als Error-Typ verwendet werden koennen.

use uniffi;

/// Einzelne Compiler-Diagnose (Fehler oder Warnung).
#[derive(Debug, Clone, uniffi::Record)]
pub struct SourceDiagnostic {
    /// "error" oder "warning"
    pub severity: String,
    /// Fehlermeldung
    pub message: String,
    /// Zeilennummer (1-basiert, 0 wenn unbekannt)
    pub line: u32,
    /// Spaltennummer (1-basiert, 0 wenn unbekannt)
    pub column: u32,
}

/// Kompilierungsfehler mit einer Liste von Diagnosen.
/// Muss ein Enum sein, da uniffi::Error nur auf Enums funktioniert.
#[derive(Debug, Clone, uniffi::Error)]
pub enum TypstCompilationError {
    /// Kompilierungsfehler mit Diagnosen
    CompileError {
        diagnostics: Vec<SourceDiagnostic>,
        summary: String,
    },
    /// PDF-Export-Fehler
    ExportError {
        diagnostics: Vec<SourceDiagnostic>,
        summary: String,
    },
}

impl TypstCompilationError {
    /// Zugriff auf Diagnosen unabhaengig von der Variante.
    pub fn diagnostics(&self) -> &[SourceDiagnostic] {
        match self {
            Self::CompileError { diagnostics, .. } => diagnostics,
            Self::ExportError { diagnostics, .. } => diagnostics,
        }
    }

    /// Zugriff auf die Zusammenfassung.
    pub fn summary(&self) -> &str {
        match self {
            Self::CompileError { summary, .. } => summary,
            Self::ExportError { summary, .. } => summary,
        }
    }

    /// Erstellt einen Kompilierungsfehler aus Typst-SourceDiagnostics.
    pub fn from_source_diagnostics(
        world: &impl typst::World,
        errors: ecow::EcoVec<typst::diag::SourceDiagnostic>,
    ) -> Self {
        let diagnostics: Vec<SourceDiagnostic> = errors
            .iter()
            .map(|diag| {
                let (line, column) = diag
                    .span
                    .id()
                    .and_then(|id| {
                        let source = world.source(id).ok()?;
                        let range = source.range(diag.span)?;
                        let line = source.byte_to_line(range.start)?;
                        let column = source.byte_to_column(range.start)?;
                        Some((line as u32 + 1, column as u32 + 1))
                    })
                    .unwrap_or((0, 0));

                SourceDiagnostic {
                    severity: match diag.severity {
                        typst::diag::Severity::Error => "error".to_string(),
                        typst::diag::Severity::Warning => "warning".to_string(),
                    },
                    message: diag.message.to_string(),
                    line,
                    column,
                }
            })
            .collect();

        let summary = diagnostics
            .iter()
            .map(|d| format!("{}:{}: {}", d.line, d.column, d.message))
            .collect::<Vec<_>>()
            .join("\n");

        Self::CompileError {
            diagnostics,
            summary,
        }
    }

    /// Erstellt einen Fehler fuer PDF-Export-Probleme.
    pub fn new_export_error(messages: Vec<String>) -> Self {
        let diagnostics: Vec<SourceDiagnostic> = messages
            .iter()
            .map(|msg| SourceDiagnostic {
                severity: "error".to_string(),
                message: msg.clone(),
                line: 0,
                column: 0,
            })
            .collect();

        let summary = messages.join("\n");

        Self::ExportError {
            diagnostics,
            summary,
        }
    }
}

impl std::fmt::Display for TypstCompilationError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.summary())
    }
}
