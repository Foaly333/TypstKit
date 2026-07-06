//
//  NativeTypstPDFPreview.swift
//  TypstEditorKit
//
//  Native PDF-Vorschau mit PDFKit (kein WebView). Laeuft auf iOS und macOS.
//  Zeigt kompilierte PDF-Dokumente oder Kompilierungsfehler an.
//

import SwiftUI
import PDFKit
import TypstCompilerKit

/// Zeigt ein PDFDocument nativ mit PDFKit an.
/// Wechselt automatisch zwischen Vorschau, Fehleranzeige und Platzhalter.
public struct NativeTypstPDFPreview: View {
    let document: PDFDocument?
    let pdfDataCount: Int
    let isCompiling: Bool
    let errors: [NativeTypstDiagnostic]
    let errorSummary: String?
    var onFullscreen: (() -> Void)?
    var onExport: (() -> Void)?

    public init(
        document: PDFDocument?,
        pdfDataCount: Int,
        isCompiling: Bool,
        errors: [NativeTypstDiagnostic],
        errorSummary: String?,
        onFullscreen: (() -> Void)? = nil,
        onExport: (() -> Void)? = nil
    ) {
        self.document = document
        self.pdfDataCount = pdfDataCount
        self.isCompiling = isCompiling
        self.errors = errors
        self.errorSummary = errorSummary
        self.onFullscreen = onFullscreen
        self.onExport = onExport
    }

    public var body: some View {
        ZStack {
            if let document {
                NativeTypstPDFKitView(document: document, dataCount: pdfDataCount)
            } else if !errors.isEmpty {
                NativeTypstErrorView(errors: errors)
            } else if let errorSummary {
                ContentUnavailableView(
                    "Kompilierungsfehler",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorSummary)
                )
            } else {
                ContentUnavailableView(
                    "Keine Vorschau",
                    systemImage: "doc.text",
                    description: Text("Gib Typst-Code ein, um eine Vorschau zu sehen.")
                )
            }

            if isCompiling {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        ProgressView("Kompiliere...")
                            .padding(12)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                        Spacer()
                    }
                    Spacer()
                }
            }

            if document != nil {
                VStack {
                    HStack {
                        Spacer()
                        VStack(spacing: 12) {
                            if let onFullscreen {
                                Button {
                                    onFullscreen()
                                } label: {
                                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                                        .font(.body)
                                        .frame(width: 36, height: 36)
                                        .background(.white.opacity(0.7), in: Circle())
                                }
                            }
                            if let onExport {
                                Button {
                                    onExport()
                                } label: {
                                    Image(systemName: "square.and.arrow.up")
                                        .font(.body)
                                        .frame(width: 36, height: 36)
                                        .background(.white.opacity(0.7), in: Circle())
                                }
                            }
                        }
                        .padding(12)
                    }
                    Spacer()
                }
            }
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
        .shadow(radius: 6, y: 2)
        .padding()
    }
}

// MARK: - PDFKit Representable (iOS + macOS)

#if canImport(UIKit)

/// UIViewRepresentable Wrapper fuer PDFView.
/// Verwendet einen Coordinator mit Daten-Hash, um unnoetige Updates zu vermeiden
/// und AttributeGraph-Zyklen zu verhindern.
struct NativeTypstPDFKitView: UIViewRepresentable {
    let document: PDFDocument
    let dataCount: Int

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView()
        configure(pdfView)
        pdfView.document = document
        context.coordinator.lastDataCount = dataCount
        return pdfView
    }

    func updateUIView(_ uiView: PDFView, context: Context) {
        guard dataCount != context.coordinator.lastDataCount else { return }
        context.coordinator.lastDataCount = dataCount
        uiView.document = document
    }

    final class Coordinator {
        var lastDataCount = 0
    }
}

#elseif canImport(AppKit)

/// NSViewRepresentable Wrapper fuer PDFView (macOS).
struct NativeTypstPDFKitView: NSViewRepresentable {
    let document: PDFDocument
    let dataCount: Int

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> PDFView {
        let pdfView = PDFView()
        configure(pdfView)
        pdfView.document = document
        context.coordinator.lastDataCount = dataCount
        return pdfView
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        guard dataCount != context.coordinator.lastDataCount else { return }
        context.coordinator.lastDataCount = dataCount
        nsView.document = document
    }

    final class Coordinator {
        var lastDataCount = 0
    }
}

#endif

/// Gemeinsame PDFView-Konfiguration fuer beide Plattformen.
private func configure(_ pdfView: PDFView) {
    pdfView.autoScales = true
    pdfView.displayMode = .singlePageContinuous
    pdfView.displayDirection = .vertical
    #if canImport(UIKit)
    pdfView.backgroundColor = .clear
    #else
    pdfView.backgroundColor = .clear
    #endif
}

// MARK: - Fehleranzeige

/// Zeigt Kompilierungsfehler mit Zeilen-/Spaltenangaben an.
struct NativeTypstErrorView: View {
    let errors: [NativeTypstDiagnostic]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(errors) { diagnostic in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: diagnostic.isError
                              ? "xmark.circle.fill"
                              : "exclamationmark.triangle.fill")
                            .foregroundStyle(diagnostic.isError ? .red : .orange)

                        VStack(alignment: .leading, spacing: 2) {
                            if diagnostic.line > 0 {
                                Text("Zeile \(diagnostic.line), Spalte \(diagnostic.column)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text(diagnostic.message)
                                .font(.callout)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .padding()
        }
    }
}

// MARK: - Previews

#Preview("Mit PDF") {
    NativeTypstPDFPreview(
        document: PDFDocument(),
        pdfDataCount: 1,
        isCompiling: false,
        errors: [],
        errorSummary: nil
    )
}

#Preview("Kompilierungsfehler") {
    NativeTypstPDFPreview(
        document: nil,
        pdfDataCount: 0,
        isCompiling: false,
        errors: [
            NativeTypstDiagnostic(severity: "error", message: "Unbekannte Funktion: #kreis", line: 3, column: 1),
            NativeTypstDiagnostic(severity: "warning", message: "Unbenutzte Variable: x", line: 1, column: 5)
        ],
        errorSummary: nil
    )
}
