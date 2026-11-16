//
//  NativeTypstEditorView.swift
//  TypstEditorKit
//
//  Vollstaendiger Typst-Editor mit nativer PDF-Vorschau.
//  Nutzt TypstEditor fuer die Texteingabe und NativeTypstPDFPreview
//  fuer die Anzeige. Laeuft auf iOS und macOS.
//
//  Layout: Responsive Split-View (horizontal ab 800pt, sonst vertikal).
//  Mit `layout: .editorOnly` entfallen Vorschau und Trenner; die Vorschau
//  haengt dann als `NativeTypstControllerPreview` am selben Controller
//  an anderer Stelle der Hierarchie. Die eigenen Toolbar-Eintraege
//  (Auto-Kompilieren, Kompilieren, Export) lassen sich unabhaengig davon
//  ueber `toolbarItems:` abschalten.
//
//  App-spezifische Quelltext-Zusammensetzung (Header, Snippets etc.)
//  wird ueber `sourceBuilder` injiziert; zusaetzliche Editor-Menuepunkte
//  ueber `extraMenuItems`.
//

import SwiftUI
import PDFKit
import TypstCompilerKit

/// Darstellung von `NativeTypstEditorView`.
public enum NativeTypstEditorLayout: Sendable, Hashable {
    /// Editor und eingebaute PDF-Vorschau mit verschiebbarem Trenner (Standard).
    case editorAndPreview
    /// Nur der Editor, ohne eingebaute Vorschau und ohne Trenner.
    ///
    /// Kompiliert wird weiterhin ueber den Controller der View (Auto-Compile
    /// mit Debounce; Knoepfe gemaess `toolbarItems`). Die Vorschau zeigt
    /// ein `NativeTypstControllerPreview` an beliebiger Stelle, das **denselben**
    /// Controller erhaelt — dafuer den Controller ausserhalb anlegen und per
    /// `controller:` uebergeben. Die Vorschau beobachtet nur, sie kompiliert nicht.
    case editorOnly
}

/// Eintraege, die `NativeTypstEditorView` in die Toolbar der umgebenden
/// Navigation haengt. Unabhaengig von `NativeTypstEditorLayout`.
///
/// Standard ist `.all` (bisheriges Verhalten). Eine App mit eigener Toolbar
/// waehlt `[]` (keine Eintraege) und loest die Funktionen selbst aus:
/// - Auto-Kompilieren ueber das `autoCompile`-Binding,
/// - Kompilieren ueber `NativeTypstController.compileNow(source:)`,
/// - Export ueber `NativeTypstController.createTemporaryPDFFile(title:)`.
public struct NativeTypstEditorToolbarItems: OptionSet, Sendable, Hashable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// Schalter „Auto-Kompilieren“.
    public static let autoCompileToggle = NativeTypstEditorToolbarItems(rawValue: 1 << 0)
    /// Knopf „Kompilieren“ (erscheint nur bei ausgeschaltetem Auto-Kompilieren).
    public static let compileButton = NativeTypstEditorToolbarItems(rawValue: 1 << 1)
    /// Knopf „PDF exportieren“ (Share-Sheet auf iOS, Sichern-Dialog auf macOS).
    public static let exportButton = NativeTypstEditorToolbarItems(rawValue: 1 << 2)

    /// Alle Eintraege (Standard).
    public static let all: NativeTypstEditorToolbarItems = [.autoCompileToggle, .compileButton, .exportButton]
}

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
    private let layout: NativeTypstEditorLayout
    private let toolbarItems: NativeTypstEditorToolbarItems
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
    ///     iCloud-Bildkonfiguration oder zusaetzlichen Package-Dateien).
    ///     Wird beim ersten Erscheinen uebernommen; bei `.editorOnly` ist er der
    ///     gemeinsame Kompilierstand fuer eine externe Vorschau.
    ///   - exportTitle: Titel fuer den PDF-Export-Dateinamen
    ///   - autoCompile: Optionales externes Binding fuer den Auto-Kompilier-Zustand
    ///   - layout: Mit oder ohne eingebaute Vorschau (Standard: mit)
    ///   - toolbarItems: Eigene Toolbar-Eintraege des Editors (Standard: alle)
    ///   - sourceBuilder: Baut aus dem Klartext den kompilierbaren Provider
    ///     (Standard: Klartext unveraendert)
    ///   - extraMenuItems: Zusaetzliche Menuepunkte fuer den Editor
    public init(
        text: Binding<AttributedString>,
        compiler: NativeTypstCompilerProtocol,
        controller: NativeTypstController? = nil,
        exportTitle: String = "",
        autoCompile: Binding<Bool>? = nil,
        layout: NativeTypstEditorLayout = .editorAndPreview,
        toolbarItems: NativeTypstEditorToolbarItems = .all,
        sourceBuilder: @escaping (String) -> any TypstProvidingProtocol = { $0 },
        @ViewBuilder extraMenuItems: @escaping () -> ExtraMenu
    ) {
        self._text = text
        self.exportTitle = exportTitle
        self.layout = layout
        self.toolbarItems = toolbarItems
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
    /// Parameter wie beim editierbaren Init; `toolbarItems` Standard: alle.
    public init(
        provider: any TypstProvidingProtocol,
        compiler: NativeTypstCompilerProtocol,
        controller: NativeTypstController? = nil,
        autoCompile: Binding<Bool>? = nil,
        layout: NativeTypstEditorLayout = .editorAndPreview,
        toolbarItems: NativeTypstEditorToolbarItems = .all,
        @ViewBuilder extraMenuItems: @escaping () -> ExtraMenu
    ) {
        self._text = .constant(AttributedString(provider.typst))
        self.exportTitle = provider.title
        self.layout = layout
        self.toolbarItems = toolbarItems
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
        content
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
            if toolbarItems.contains(.autoCompileToggle) {
                ToolbarItem(placement: .primaryAction) {
                    Toggle(isOn: autoCompile) {
                        Label(
                            "Auto-Kompilieren",
                            systemImage: autoCompile.wrappedValue ? "bolt.circle.fill" : "bolt.slash.circle"
                        )
                    }
                }
            }
            if toolbarItems.contains(.compileButton), !autoCompile.wrappedValue {
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
            if toolbarItems.contains(.exportButton) {
                ToolbarItem(placement: .primaryAction) {
                    NativeTypstExportButton(
                        controller: controller,
                        exportTitle: exportTitle,
                        pdfExportURL: $pdfExportURL,
                        showShareSheet: $showShareSheet
                    )
                }
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

    // MARK: - Layout-Auswahl

    @ViewBuilder
    private var content: some View {
        switch layout {
        case .editorOnly:
            TypstEditor(text: $text, extraMenuItems: extraMenuItems)
        case .editorAndPreview:
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

            NativeTypstControllerPreview(controller: controller)
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

            NativeTypstControllerPreview(controller: controller)
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
        layout: NativeTypstEditorLayout = .editorAndPreview,
        toolbarItems: NativeTypstEditorToolbarItems = .all,
        sourceBuilder: @escaping (String) -> any TypstProvidingProtocol = { $0 }
    ) {
        self.init(
            text: text,
            compiler: compiler,
            controller: controller,
            exportTitle: exportTitle,
            autoCompile: autoCompile,
            layout: layout,
            toolbarItems: toolbarItems,
            sourceBuilder: sourceBuilder,
            extraMenuItems: { EmptyView() }
        )
    }

    public init(
        provider: any TypstProvidingProtocol,
        compiler: NativeTypstCompilerProtocol,
        controller: NativeTypstController? = nil,
        autoCompile: Binding<Bool>? = nil,
        layout: NativeTypstEditorLayout = .editorAndPreview,
        toolbarItems: NativeTypstEditorToolbarItems = .all
    ) {
        self.init(
            provider: provider,
            compiler: compiler,
            controller: controller,
            autoCompile: autoCompile,
            layout: layout,
            toolbarItems: toolbarItems,
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

/// PDF-Vorschau, die den Kompilierstand eines `NativeTypstController` anzeigt.
///
/// Liest den Controller erst in ihrem eigenen `body`: Nach einer Kompilierung
/// wird nur diese View neu gerendert – nicht der Elternteil und nicht der
/// TypstEditor, der den Fokus haelt. Sie kompiliert selbst nie; das uebernimmt
/// die `NativeTypstEditorView` (oder die App) am selben Controller.
///
/// Gegenstueck zu `NativeTypstEditorView(layout: .editorOnly, controller:)`.
public struct NativeTypstControllerPreview: View {
    let controller: NativeTypstController
    var onFullscreen: (() -> Void)?
    var onExport: (() -> Void)?

    public init(
        controller: NativeTypstController,
        onFullscreen: (() -> Void)? = nil,
        onExport: (() -> Void)? = nil
    ) {
        self.controller = controller
        self.onFullscreen = onFullscreen
        self.onExport = onExport
    }

    public var body: some View {
        NativeTypstPDFPreview(
            document: controller.pdfDocument,
            pdfDataCount: controller.pdfData?.count ?? 0,
            isCompiling: controller.isCompiling,
            errors: controller.compilationErrors,
            errorSummary: controller.errorSummary,
            onFullscreen: onFullscreen,
            onExport: onExport
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

#Preview("Nur Editor + externe Vorschau") {
    @Previewable @State var text = AttributedString("= Hallo Welt\n\nDies ist ein Test.")
    @Previewable @State var controller = NativeTypstController(compiler: PreviewTypstCompiler())
    NavigationStack {
        HStack(spacing: 0) {
            NativeTypstEditorView(
                text: $text,
                compiler: PreviewTypstCompiler(),
                controller: controller,
                layout: .editorOnly,
                toolbarItems: []
            )
            Divider()
            NativeTypstControllerPreview(controller: controller)
        }
    }
}
