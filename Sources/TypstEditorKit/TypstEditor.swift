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
    @Environment(\.typstEditorInsertion) private var insertion
    /// Erst nach dem ersten Fokus ist die Selektion eine echte Cursorposition.
    @State private var hadFocus = false

    /// Tokenisierter Roh-Text (anstelle des Base64 steht ein Token)
    @State private var rawTextWithTokens: String = ""
    /// Mapping token -> originaler Base64-Code
    @State private var base64Mapping: [String: String] = [:]

    @Bindable var controller = TypstEditorController()

    /// Zusaetzliche App-spezifische Menuepunkte (Snippets, Bildimport, KI etc.)
    private let extraMenuItems: () -> ExtraMenu
    /// Haengt der Editor sein Werkzeug-Menue in die Toolbar der umgebenden Navigation?
    private let showsToolsMenu: Bool
    @Environment(\.typstEditorActions) private var actions

    /// Erstellt den Editor.
    /// - Parameters:
    ///   - text: Binding zum Typst-Quelltext (inkl. Base64)
    ///   - showsToolsMenu: Werkzeug-Menue in der Toolbar der umgebenden Navigation
    ///     (Standard: ja). Ohne zeigt die App es selbst — `TypstEditorToolsMenu` mit
    ///     `TypstEditorActions` im Environment.
    ///   - extraMenuItems: Zusaetzliche Menuepunkte fuer das Werkzeug-Menue
    public init(
        text: Binding<AttributedString>,
        showsToolsMenu: Bool = true,
        @ViewBuilder extraMenuItems: @escaping () -> ExtraMenu
    ) {
        self._text = text
        self.showsToolsMenu = showsToolsMenu
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
        if showsToolsMenu {
            ToolbarItem(placement: .primaryAction) {
                TypstEditorToolsMenuButton(
                    format: formatCode,
                    copyCode: copyCode,
                    clear: clearCode,
                    extraMenuItems: extraMenuItems
                )
            }
        }
    }

    // MARK: - Werkzeug-Aktionen (Toolbar-Menue und `TypstEditorActions`)

    /// Rueckt den aktuellen Stand ein und gibt ihn sofort nach aussen.
    private func formatCode() {
        debounceTask?.cancel()
        let externalRaw = controller.restoreBase64(from: rawTextWithTokens, mapping: base64Mapping)
        let formattedExternal = controller.formattedIndent(from: externalRaw)
        let result = controller.extractBase64Tokens(from: formattedExternal)
        rawTextWithTokens = result.tokenized
        base64Mapping = result.mapping
        let display = controller.tokenizedToDisplay(rawTextWithTokens, mapping: base64Mapping)
        internalText = AttributedString(display)
        text = AttributedString(formattedExternal)
        applySyntaxHighlight()
    }

    private func copyCode() {
        let externalRaw = controller.restoreBase64(from: rawTextWithTokens, mapping: base64Mapping)
        Self.copyToPasteboard(externalRaw)
    }

    private func clearCode() {
        debounceTask?.cancel()
        internalText = ""
        rawTextWithTokens = ""
        base64Mapping = [:]
        text = ""
    }

    private func perform(_ command: TypstEditorActions.Command) {
        switch command {
        case .format: formatCode()
        case .copyCode: copyCode()
        case .clear: clearCode()
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
                .onChange(of: isFocused) { _, focused in
                    if focused { hadFocus = true }
                }
                .onChange(of: insertion?.pending ?? []) { _, pending in
                    guard !pending.isEmpty, let insertion else { return }
                    for code in insertion.takeAll() { insertAtCursor(code) }
                }
                .onChange(of: actions?.pending ?? []) { _, pending in
                    guard !pending.isEmpty, let actions else { return }
                    for command in actions.takeAll() { perform(command) }
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
        .onAppear {
            actions?.attach()
        }
        .onDisappear {
            debounceTask?.cancel()
            actions?.detach()
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

    /// Fuegt Code als eigene Zeile an der Cursorposition ein (bzw. am Ende, wenn der
    /// Editor noch nie fokussiert war) und gibt den Stand sofort nach aussen — ohne
    /// Debounce, damit ein Schliessen der View die Einfuegung nicht verliert.
    private func insertAtCursor(_ code: String) {
        if hadFocus {
            internalText.replaceSelection(&selection, withCharacters: "\n" + code + "\n")
        } else {
            let current = String(internalText.characters)
            let separator = current.isEmpty || current.hasSuffix("\n") ? "" : "\n"
            internalText.append(AttributedString(separator + code))
        }
        let tokenized = controller.displayToTokenized(String(internalText.characters), mapping: base64Mapping)
        rawTextWithTokens = tokenized
        text = AttributedString(controller.restoreBase64(from: tokenized, mapping: base64Mapping))
        applySyntaxHighlight()
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
    public init(text: Binding<AttributedString>, showsToolsMenu: Bool = true) {
        self.init(text: text, showsToolsMenu: showsToolsMenu, extraMenuItems: { EmptyView() })
    }
}

// MARK: - Previews

#Preview("Typst Editor") {
    @Previewable @State var text = AttributedString("#circle[Hallo Welt]")
    NavigationStack {
        TypstEditor(text: $text)
    }
}
