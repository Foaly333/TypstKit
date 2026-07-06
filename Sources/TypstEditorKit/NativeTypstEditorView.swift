//
//  NativeTypstEditorView.swift
//  TypstEditorKit
//
//  Vollstaendiger Typst-Editor mit nativer PDF-Vorschau.
//  Nutzt TypstEditor fuer die Texteingabe und NativeTypstPDFPreview
//  fuer die Anzeige. Laeuft auf iOS und macOS.
//
//  Layout: Responsive Split-View (horizontal ab 800pt, sonst vertikal).
//
//  App-spezifische Quelltext-Zusammensetzung (Header, Snippets etc.)
//  wird ueber `sourceBuilder` injiziert; zusaetzliche Editor-Menuepunkte
//  ueber `extraMenuItems`.
//

import SwiftUI
import PDFKit
import TypstCompilerKit

public struct NativeTypstEditorView<ExtraMenu: View>: View {
    @Binding var text: AttributedString
    @State private var controller: NativeTypstController

    /// Auto-Kompilieren: extern per Binding steuerbar, sonst intern via AppStorage.
    private let externalAutoCompile: Binding<Bool>?
    @AppStorage("TypstKit.autoCompile") private var storedAutoCompile = true

    /// Abgeleiteter Klartext fuer Change-Tracking (vermeidet AttributedString-Vergleich).
    @State private var plainText = ""

    // Split-View State
    @State private var splitRatio: CGFloat = 0.5
    @State private var hSplitRatio: CGFloat = 0.5
    @State private var dragStartRatio: CGFloat?

    // PDF-Export
    @State private var showShareSheet = false
    @State private var pdfExportURL: URL?

    private let sideBySideMinWidth: CGFloat = 800
    private let minPaneHeight: CGFloat = 120
    private let handleThickness: CGFloat = 8
    private let exportTitle: String
    private let readOnlyProvider: (any TypstProvidingProtocol)?

    /// Baut aus dem aktuellen Klartext den kompilierbaren Provider.
    /// Apps injizieren hier ihre eigene Logik (Header, Snippet-Praefixe etc.).
    private let sourceBuilder: (String) -> any TypstProvidingProtocol

    /// Zusaetzliche Menuepunkte fuer das Editor-Werkzeug-Menue.
    private let extraMenuItems: () -> ExtraMenu

    /// Erstellt die View mit editierbarem Text.
    /// - Parameters:
    ///   - text: Binding zum Typst-Quelltext
    ///   - compiler: Der zu verwendende Compiler-Service
    ///   - controller: Optionaler vorkonfigurierter Controller (z.B. mit
    ///     iCloud-Bildkonfiguration oder zusaetzlichen Package-Dateien)
    ///   - exportTitle: Titel fuer den PDF-Export-Dateinamen
    ///   - autoCompile: Optionales externes Binding fuer den Auto-Kompilier-Zustand
    ///   - sourceBuilder: Baut aus dem Klartext den kompilierbaren Provider
    ///     (Standard: Klartext unveraendert)
    ///   - extraMenuItems: Zusaetzliche Menuepunkte fuer den Editor
    public init(
        text: Binding<AttributedString>,
        compiler: NativeTypstCompilerProtocol,
        controller: NativeTypstController? = nil,
        exportTitle: String = "",
        autoCompile: Binding<Bool>? = nil,
        sourceBuilder: @escaping (String) -> any TypstProvidingProtocol = { $0 },
        @ViewBuilder extraMenuItems: @escaping () -> ExtraMenu
    ) {
        self._text = text
        self.exportTitle = exportTitle
        self.externalAutoCompile = autoCompile
        self.sourceBuilder = sourceBuilder
        self.readOnlyProvider = nil
        self.extraMenuItems = extraMenuItems
        self._controller = State(
            initialValue: controller ?? NativeTypstController(compiler: compiler, debounceDelay: 2000)
        )
    }

    /// Erstellt die View mit einem TypstProvidingProtocol (read-only).
    /// Fuer aggregierte Typen, deren Typst nicht direkt geaendert werden kann.
    public init(
        provider: any TypstProvidingProtocol,
        compiler: NativeTypstCompilerProtocol,
        controller: NativeTypstController? = nil,
        autoCompile: Binding<Bool>? = nil,
        @ViewBuilder extraMenuItems: @escaping () -> ExtraMenu
    ) {
        self._text = .constant(AttributedString(provider.typst))
        self.exportTitle = provider.title
        self.externalAutoCompile = autoCompile
        self.sourceBuilder = { $0 }
        self.readOnlyProvider = provider
        self.extraMenuItems = extraMenuItems
        self._controller = State(
            initialValue: controller ?? NativeTypstController(compiler: compiler, debounceDelay: 2000)
        )
    }

    private var autoCompile: Binding<Bool> {
        externalAutoCompile ?? $storedAutoCompile
    }

    public var body: some View {
        GeometryReader { geo in
            let totalW = geo.size.width
            let totalH = geo.size.height
            let isSideBySide = totalW >= sideBySideMinWidth

            if isSideBySide {
                horizontalLayout(totalWidth: totalW, totalHeight: totalH)
            } else {
                verticalLayout(totalWidth: totalW, totalHeight: totalH)
            }
        }
        .onChange(of: text) { _, newVal in
            let newPlain = String(newVal.characters)
            guard newPlain != plainText else { return }
            plainText = newPlain
        }
        .task(id: plainText) {
            guard !plainText.isEmpty else { return }
            guard autoCompile.wrappedValue else { return }
            controller.scheduleCompilation(source: currentSource())
        }
        .onChange(of: autoCompile.wrappedValue) { _, isOn in
            // Beim Einschalten sofort eine Kompilierung auslösen, damit die Vorschau aktuell ist.
            guard isOn, !plainText.isEmpty else { return }
            controller.scheduleCompilation(source: currentSource())
        }
        .onAppear {
            plainText = String(text.characters)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Toggle(isOn: autoCompile) {
                    Label(
                        "Auto-Kompilieren",
                        systemImage: autoCompile.wrappedValue ? "bolt.circle.fill" : "bolt.slash.circle"
                    )
                }
            }
            if !autoCompile.wrappedValue {
                ToolbarItem(placement: .primaryAction) {
                    NativeTypstManualCompileButton(
                        controller: controller,
                        isDisabled: plainText.isEmpty,
                        compile: {
                            guard !plainText.isEmpty else { return }
                            controller.compileNow(source: currentSource())
                        }
                    )
                }
            }
            ToolbarItem(placement: .primaryAction) {
                NativeTypstExportButton(
                    controller: controller,
                    exportTitle: exportTitle,
                    pdfExportURL: $pdfExportURL,
                    showShareSheet: $showShareSheet
                )
            }
        }
        #if os(iOS)
        .sheet(isPresented: $showShareSheet) {
            if let url = pdfExportURL {
                TypstShareSheet(activityItems: [url])
            }
        }
        #endif
        .onDisappear {
            controller.cancelCompilation()
        }
    }

    // MARK: - Source Building

    /// Baut den passenden TypstProvider fuer den aktuellen Modus.
    private func currentSource() -> any TypstProvidingProtocol {
        if let readOnlyProvider {
            return readOnlyProvider
        }
        return sourceBuilder(plainText)
    }

    // MARK: - Horizontal Layout (Side-by-Side)

    @ViewBuilder
    private func horizontalLayout(totalWidth: CGFloat, totalHeight: CGFloat) -> some View {
        let minRatio = 300 / max(totalWidth, 1)
        let clamped = max(minRatio, min(1 - minRatio, hSplitRatio))
        let leftWidth = max(300, clamped * totalWidth)
        let rightWidth = max(300, totalWidth - leftWidth - handleThickness)

        HStack(spacing: 0) {
            TypstEditor(text: $text, extraMenuItems: extraMenuItems)
                .frame(width: leftWidth, height: totalHeight)

            NativeTypstVerticalDividerHandle()
                .frame(width: handleThickness, height: totalHeight)
                .gesture(horizontalDragGesture(totalWidth: totalWidth))

            NativeTypstPDFPreviewPane(controller: controller)
                .frame(width: rightWidth, height: totalHeight)
        }
        .animation(.snappy(duration: 0.12), value: hSplitRatio)
    }

    // MARK: - Vertical Layout (Stacked)

    @ViewBuilder
    private func verticalLayout(totalWidth: CGFloat, totalHeight: CGFloat) -> some View {
        let minRatio = minPaneHeight / max(totalHeight, 1)
        let clampedRatio = max(minRatio, min(1 - minRatio, splitRatio))
        let topHeight = max(minPaneHeight, clampedRatio * totalHeight)
        let bottomHeight = max(minPaneHeight, totalHeight - topHeight - handleThickness)

        VStack(spacing: 0) {
            TypstEditor(text: $text, extraMenuItems: extraMenuItems)
                .frame(height: topHeight)

            NativeTypstHorizontalDividerHandle()
                .frame(height: handleThickness)
                .gesture(verticalDragGesture(totalHeight: totalHeight))

            NativeTypstPDFPreviewPane(controller: controller)
                .frame(height: bottomHeight)
        }
        .animation(.snappy(duration: 0.12), value: splitRatio)
    }

    // MARK: - Drag Gestures

    private func verticalDragGesture(totalHeight: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragStartRatio == nil { dragStartRatio = splitRatio }
                let start = dragStartRatio ?? splitRatio
                let delta = value.translation.height / max(totalHeight, 1)
                var next = start + delta
                let minRatio = minPaneHeight / max(totalHeight, 1)
                next = max(minRatio, min(1 - minRatio, next))
                splitRatio = next
            }
            .onEnded { _ in
                dragStartRatio = nil
            }
    }

    private func horizontalDragGesture(totalWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragStartRatio == nil { dragStartRatio = hSplitRatio }
                let start = dragStartRatio ?? hSplitRatio
                let delta = value.translation.width / max(totalWidth, 1)
                var next = start + delta
                let minRatio = 300 / max(totalWidth, 1)
                next = max(minRatio, min(1 - minRatio, next))
                hSplitRatio = next
            }
            .onEnded { _ in
                dragStartRatio = nil
            }
    }
}

// MARK: - Convenience-Inits ohne Zusatz-Menue

extension NativeTypstEditorView where ExtraMenu == EmptyView {
    public init(
        text: Binding<AttributedString>,
        compiler: NativeTypstCompilerProtocol,
        controller: NativeTypstController? = nil,
        exportTitle: String = "",
        autoCompile: Binding<Bool>? = nil,
        sourceBuilder: @escaping (String) -> any TypstProvidingProtocol = { $0 }
    ) {
        self.init(
            text: text,
            compiler: compiler,
            controller: controller,
            exportTitle: exportTitle,
            autoCompile: autoCompile,
            sourceBuilder: sourceBuilder,
            extraMenuItems: { EmptyView() }
        )
    }

    public init(
        provider: any TypstProvidingProtocol,
        compiler: NativeTypstCompilerProtocol,
        controller: NativeTypstController? = nil,
        autoCompile: Binding<Bool>? = nil
    ) {
        self.init(
            provider: provider,
            compiler: compiler,
            controller: controller,
            autoCompile: autoCompile,
            extraMenuItems: { EmptyView() }
        )
    }
}

// MARK: - Export Button (isolierte Subview, um Fokus-Verlust zu vermeiden)

/// Eigene Subview fuer den Export-Button, damit die Observation von
/// `controller.pdfData` nicht die gesamte NativeTypstEditorView invalidiert.
struct NativeTypstExportButton: View {
    let controller: NativeTypstController
    let exportTitle: String
    @Binding var pdfExportURL: URL?
    @Binding var showShareSheet: Bool

    var body: some View {
        Button {
            if let url = controller.createTemporaryPDFFile(title: exportTitle) {
                pdfExportURL = url
                #if os(iOS)
                showShareSheet = true
                #else
                TypstPDFExport.presentSavePanel(for: url)
                #endif
            }
        } label: {
            Label("PDF exportieren", systemImage: "square.and.arrow.up")
        }
        .disabled(controller.pdfData == nil)
    }
}

// MARK: - Manual Compile Button (isolierte Subview, um Fokus-Verlust zu vermeiden)

/// Eigene Subview fuer den manuellen Kompilier-Button. Beobachtet
/// `controller.isCompiling` lokal, damit der TypstEditor in der Elternsicht
/// nicht jedesmal neu gerendert wird, wenn die Kompilierung startet/endet.
struct NativeTypstManualCompileButton: View {
    let controller: NativeTypstController
    let isDisabled: Bool
    let compile: () -> Void

    var body: some View {
        Button(action: compile) {
            Label("Kompilieren", systemImage: "play.circle")
        }
        .disabled(isDisabled || controller.isCompiling)
    }
}

// MARK: - PDF Preview Pane (isolierte Subview, um Fokus-Verlust zu vermeiden)

/// Liest den Controller und rendert die PDF-Vorschau.
/// Dadurch wird beim Neu-Rendern nach der Kompilierung nur diese Subview
/// aktualisiert – nicht der TypstEditor, der den Fokus haelt.
struct NativeTypstPDFPreviewPane: View {
    let controller: NativeTypstController

    var body: some View {
        NativeTypstPDFPreview(
            document: controller.pdfDocument,
            pdfDataCount: controller.pdfData?.count ?? 0,
            isCompiling: controller.isCompiling,
            errors: controller.compilationErrors,
            errorSummary: controller.errorSummary
        )
    }
}

// MARK: - Divider Handles

struct NativeTypstHorizontalDividerHandle: View {
    var body: some View {
        ZStack {
            Rectangle()
                .fill(.quaternary)
            Capsule(style: .continuous)
                .fill(.secondary)
                .frame(width: 64, height: 4)
        }
        .contentShape(Rectangle())
        .accessibilityLabel("Groessenregler zwischen Editor und Vorschau")
        .accessibilityAddTraits(.isButton)
    }
}

struct NativeTypstVerticalDividerHandle: View {
    var body: some View {
        ZStack {
            Rectangle()
                .fill(.quaternary)
            Capsule(style: .continuous)
                .fill(.secondary)
                .frame(width: 4, height: 64)
        }
        .contentShape(Rectangle())
        .accessibilityLabel("Groessenregler zwischen Editor und Vorschau (vertikal)")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Plattformspezifischer Export

#if os(iOS)
import UIKit

/// ShareSheet via UIActivityViewController (iOS).
struct TypstShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#endif

#if os(macOS)
import AppKit
import UniformTypeIdentifiers

/// PDF-Export via NSSavePanel (macOS).
enum TypstPDFExport {
    static func presentSavePanel(for temporaryURL: URL) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = temporaryURL.lastPathComponent
        panel.canCreateDirectories = true

        if panel.runModal() == .OK, let destination = panel.url {
            try? FileManager.default.removeItem(at: destination)
            try? FileManager.default.copyItem(at: temporaryURL, to: destination)
        }
    }
}
#endif

// MARK: - Previews

#Preview("Native Typst Editor") {
    @Previewable @State var text = AttributedString("= Hallo Welt\n\nDies ist ein Test.")
    NavigationStack {
        NativeTypstEditorView(
            text: $text,
            compiler: PreviewTypstCompiler()
        )
    }
}
