//
//  NativeTypstRenderView.swift
//  TypstEditorKit
//
//  Leichtgewichtige View, die Typst-Quelltext nativ kompiliert
//  und als PDF anzeigt — ohne Editor. Laeuft auf iOS und macOS.
//  Wiederverwendet NativeTypstPDFPreview und NativeTypstController.
//

import SwiftUI
import PDFKit
import TypstCompilerKit

/// Rendert Typst-Quelltext als PDF-Vorschau ohne Editor.
/// Kompiliert standardmaessig automatisch bei Erscheinen und bei Aenderung des Quelltexts.
/// Mit `autoCompile = false` muss die Kompilierung manuell ueber den `compileTrigger`
/// (typischerweise ein Counter im Eltern-View) angestossen werden.
public struct NativeTypstRenderView: View {
    private let resolvedSource: String
    private let resolvedTitle: String
    private let autoCompile: Bool
    private let compileTrigger: Int

    /// Optionaler App-Handler fuer den Export. Bekommt die URL der temporaeren
    /// PDF-Datei. nil = Standard-Export (ShareSheet auf iOS, SavePanel auf macOS).
    private let onExport: ((URL) -> Void)?

    @State private var controller: NativeTypstController
    @State private var showFullscreen = false
    #if os(iOS)
    @State private var shareItem: TypstShareItem?
    #endif

    public init(
        source: some TypstProvidingProtocol,
        compiler: any NativeTypstCompilerProtocol,
        controller: NativeTypstController? = nil,
        autoCompile: Bool = true,
        compileTrigger: Int = 0,
        onExport: ((URL) -> Void)? = nil
    ) {
        self.resolvedSource = source.typst
        self.resolvedTitle = source.title
        self.autoCompile = autoCompile
        self.compileTrigger = compileTrigger
        self.onExport = onExport
        self._controller = State(
            initialValue: controller ?? NativeTypstController(compiler: compiler)
        )
    }

    public var body: some View {
        NativeTypstPDFPreview(
            document: controller.pdfDocument,
            pdfDataCount: controller.pdfData?.count ?? 0,
            isCompiling: controller.isCompiling,
            errors: controller.compilationErrors,
            errorSummary: controller.errorSummary,
            onFullscreen: {
                showFullscreen = true
            },
            onExport: {
                guard let url = controller.createTemporaryPDFFile(title: resolvedTitle) else { return }
                if let onExport {
                    onExport(url)
                } else {
                    #if os(iOS)
                    shareItem = TypstShareItem(url: url)
                    #else
                    TypstPDFExport.presentSavePanel(for: url)
                    #endif
                }
            }
        )
        .frame(minHeight: 200)
        .task {
            guard autoCompile, !resolvedSource.isEmpty else { return }
            await controller.compile(source: resolvedSource)
        }
        .onChange(of: resolvedSource) { _, newSource in
            guard autoCompile, !newSource.isEmpty else { return }
            controller.scheduleCompilation(source: newSource)
        }
        .onChange(of: compileTrigger) { _, _ in
            guard !autoCompile, !resolvedSource.isEmpty else { return }
            controller.compileNow(source: resolvedSource)
        }
        .sheet(isPresented: $showFullscreen) {
            if let document = controller.pdfDocument {
                NavigationStack {
                    TypstPDFFullscreenView(
                        document: document,
                        dataCount: controller.pdfData?.count ?? 0,
                        title: resolvedTitle
                    )
                }
            }
        }
        #if os(iOS)
        .sheet(item: $shareItem) { item in
            TypstShareSheet(activityItems: [item.url])
        }
        #endif
    }
}

#if os(iOS)
/// Identifizierbarer Wrapper fuer die Share-Sheet-Praesentation.
struct TypstShareItem: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}
#endif

// MARK: - Fullscreen-Anzeige

/// Einfache Vollbild-Anzeige eines kompilierten PDF-Dokuments.
struct TypstPDFFullscreenView: View {
    let document: PDFDocument
    let dataCount: Int
    let title: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NativeTypstPDFKitView(document: document, dataCount: dataCount)
            .navigationTitle(title.isEmpty ? "Vorschau" : title)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
    }
}

// MARK: - Previews

#Preview("Render View") {
    NativeTypstRenderView(
        source: "= Hallo Welt\n\nDies ist ein gerendertes Dokument.",
        compiler: PreviewTypstCompiler()
    )
}

#Preview("Leerer Quelltext") {
    NativeTypstRenderView(
        source: "",
        compiler: PreviewTypstCompiler()
    )
}
