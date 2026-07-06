//
//  TypstEditor.swift
//  TypstEditorKit
//
//  Texteditor fuer Typst-Quelltext mit Syntax-Highlighting,
//  Base64-Maskierung, Formatierung und erweiterbarem Werkzeug-Menue.
//
//  App-spezifische Funktionen (Snippets, Bildimport, KI-Generierung)
//  werden ueber `extraMenuItems` injiziert. Externe Aenderungen am
//  `text`-Binding (z.B. eingefuegte Snippets) uebernimmt der Editor
//  automatisch.
//

import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

public struct TypstEditor<ExtraMenu: View>: View {
    @Binding var text: AttributedString

    @State private var internalText: AttributedString = ""
    @State private var selection = AttributedTextSelection()
    @State private var debounceTask: Task<Void, Never>? = nil
    @FocusState private var isFocused: Bool
    @Environment(\.colorScheme) private var colorScheme

    /// Tokenisierter Roh-Text (anstelle des Base64 steht ein Token)
    @State private var rawTextWithTokens: String = ""
    /// Mapping token -> originaler Base64-Code
    @State private var base64Mapping: [String: String] = [:]

    @Bindable var controller = TypstEditorController()

    /// Zusaetzliche App-spezifische Menuepunkte (Snippets, Bildimport, KI etc.)
    private let extraMenuItems: () -> ExtraMenu

    /// Erstellt den Editor.
    /// - Parameters:
    ///   - text: Binding zum Typst-Quelltext (inkl. Base64)
    ///   - extraMenuItems: Zusaetzliche Menuepunkte fuer das Werkzeug-Menue
    public init(
        text: Binding<AttributedString>,
        @ViewBuilder extraMenuItems: @escaping () -> ExtraMenu
    ) {
        self._text = text
        self.extraMenuItems = extraMenuItems
    }

    public var selectedText: AttributedString {
        AttributedString(internalText[selection])
    }

    /// Binding für String, das z.B. beim Bildimport benutzt werden kann.
    /// - get: gibt den echten Typst-Code *inklusive* Base64 zurück.
    /// - set: nimmt neuen Code, tokenisiert Base64 und aktualisiert alle Zustände.
    public var stringBinding: Binding<String> {
        Binding<String> {
            // Echte Ausgabe inkl. Base64
            controller.restoreBase64(from: rawTextWithTokens, mapping: base64Mapping)
        } set: { newValue in
            // Neue Eingabe: Base64 extrahieren, durch Tokens ersetzen, Mapping bauen
            let result = controller.extractBase64Tokens(from: newValue)
            rawTextWithTokens = result.tokenized
            base64Mapping = result.mapping

            let display = controller.tokenizedToDisplay(rawTextWithTokens, mapping: base64Mapping)
            internalText = AttributedString(display)

            // Nach außen geht immer der echte Code
            text = AttributedString(newValue)
        }
    }

    @ToolbarContentBuilder
    var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                // App-spezifische Menuepunkte (Snippets, Bildimport, KI ...)
                extraMenuItems()

                Divider()

                // Code-Werkzeuge
                Button {
                    let externalRaw = controller.restoreBase64(from: rawTextWithTokens, mapping: base64Mapping)
                    let formattedExternal = controller.formattedIndent(from: externalRaw)
                    let result = controller.extractBase64Tokens(from: formattedExternal)
                    rawTextWithTokens = result.tokenized
                    base64Mapping = result.mapping
                    let display = controller.tokenizedToDisplay(rawTextWithTokens, mapping: base64Mapping)
                    internalText = AttributedString(display)
                    text = AttributedString(formattedExternal)
                } label: {
                    Label("Formatieren", systemImage: "wand.and.stars")
                }

                Button {
                    let externalRaw = controller.restoreBase64(from: rawTextWithTokens, mapping: base64Mapping)
                    Self.copyToPasteboard(externalRaw)
                } label: {
                    Label("Code kopieren", systemImage: "doc.on.doc")
                }

                Divider()

                Button(role: .destructive) {
                    internalText = ""
                    rawTextWithTokens = ""
                    base64Mapping = [:]
                    text = ""
                } label: {
                    Label("Code leeren", systemImage: "trash")
                }
            } label: {
                Label("Typst-Werkzeuge", systemImage: "wand.and.stars.inverse")
            }
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Editor
            editorTextView
                .frame(minWidth: 200, minHeight: 200)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(12)
                .background(.thinMaterial)
                .focused($isFocused)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(
                            isFocused ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary),
                            lineWidth: isFocused ? 2 : 1
                        )
                )
                .preference(key: TypstCodePreferenceKey.self, value: selectedText)
                .attributedTextFormattingDefinition(TypstCodeFormattingDefinition())
                .onAppear {
                    // Ausgangszustand: Binding-Text enthält echten Code inkl. Base64
                    let externalRaw = String(text.characters)

                    // Base64 herausholen und durch Tokens ersetzen
                    let result = controller.extractBase64Tokens(from: externalRaw)
                    rawTextWithTokens = result.tokenized
                    base64Mapping = result.mapping

                    // Anzeige mit Platzhaltern
                    let display = controller.tokenizedToDisplay(rawTextWithTokens, mapping: base64Mapping)
                    internalText = AttributedString(display)

                    applySyntaxHighlight()
                }
                .onChange(of: internalText) { _, newValue in
                    debounceTask?.cancel()

                    // Anzeige -> zurück zu tokenisiertem Text
                    let displayString = String(newValue.characters)
                    let tokenized = controller.displayToTokenized(displayString, mapping: base64Mapping)
                    rawTextWithTokens = tokenized

                    // Echten Code inkl. Base64 rekonstruieren
                    let externalRaw = controller.restoreBase64(from: rawTextWithTokens, mapping: base64Mapping)

                    // Debounced nach außen geben + Syntax Highlight
                    debounceTask = Task { @MainActor in
                        do {
                            try await Task.sleep(nanoseconds: 400_000_000)
                        } catch {
                            return
                        }
                        if Task.isCancelled { return }

                        text = AttributedString(externalRaw)
                        applySyntaxHighlight()
                    }
                }
                .onChange(of: text) { _, newText in
                    // Externes Update des Bindings (z.B. eingefuegtes Snippet oder
                    // nach iCloud-Load eines Templates): internalText neu aufbauen,
                    // wenn der Inhalt vom aktuell angezeigten abweicht.
                    let newPlain = String(newText.characters)
                    let currentPlain = controller.restoreBase64(from: rawTextWithTokens, mapping: base64Mapping)
                    guard newPlain != currentPlain else { return }

                    let result = controller.extractBase64Tokens(from: newPlain)
                    rawTextWithTokens = result.tokenized
                    base64Mapping = result.mapping
                    let display = controller.tokenizedToDisplay(rawTextWithTokens, mapping: base64Mapping)
                    internalText = AttributedString(display)
                    applySyntaxHighlight()
                }
                .toolbar {
                    toolbar
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
        .onDisappear {
            debounceTask?.cancel()
        }
    }

    /// Plattformspezifisch konfigurierter TextEditor.
    @ViewBuilder
    private var editorTextView: some View {
        #if os(iOS)
        TextEditor(text: $internalText, selection: $selection)
            .keyboardType(.asciiCapable)
        #else
        TextEditor(text: $internalText, selection: $selection)
        #endif
    }

    func applySyntaxHighlight() {
        controller.updateLetConstraint(on: &internalText, selection: &selection)
    }

    /// Kopiert Text plattformuebergreifend ins Pasteboard.
    private static func copyToPasteboard(_ string: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = string
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #endif
    }
}

// MARK: - Convenience-Init ohne Zusatz-Menue

extension TypstEditor where ExtraMenu == EmptyView {
    public init(text: Binding<AttributedString>) {
        self.init(text: text, extraMenuItems: { EmptyView() })
    }
}

// MARK: - Previews

#Preview("Typst Editor") {
    @Previewable @State var text = AttributedString("#circle[Hallo Welt]")
    NavigationStack {
        TypstEditor(text: $text)
    }
}
