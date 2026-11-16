//
//  TypstEditorActions.swift
//  TypstEditorKit
//
//  Kanal, ueber den eine App die Werkzeug-Aktionen des Editors (Formatieren,
//  Code kopieren, Code leeren) von aussen ausloest — z. B. aus einem eigenen
//  Werkzeug-Menue im Kopf eines Editor-Bereichs statt in der Navigationsleiste.
//  Der Editor fuehrt die Aktion auf seinem aktuellen Stand aus (auch auf noch
//  nicht nach aussen gegebenen Tastendruecken) und gibt das Ergebnis sofort
//  ueber das `text`-Binding weiter.
//

import SwiftUI

/// Loest die Werkzeug-Aktionen eines `TypstEditor` von aussen aus.
///
/// Die App legt das Objekt an, setzt es ins Environment des Editors und bindet
/// ein eigenes Menue daran (fertig: `TypstEditorToolsMenu`). Ein Objekt gehoert zu
/// **einem** Editor. Solange kein Editor angebunden ist (`isAttached == false`),
/// verfallen Aufrufe — es wird nichts fuer spaeter vorgemerkt.
///
/// ```swift
/// @State private var aktionen = TypstEditorActions()
/// TypstEditor(text: $text, showsToolsMenu: false)
///     .environment(\.typstEditorActions, aktionen)
/// // an anderer Stelle:
/// TypstEditorToolsMenu(actions: aktionen) { /* App-Eintraege */ }
/// ```
@Observable
public final class TypstEditorActions {
    /// Werkzeug-Aktion, die der Editor ausfuehrt.
    enum Command: Equatable, Sendable {
        case format
        case copyCode
        case clear
    }

    /// Noch nicht ausgefuehrte Aktionen, in Reihenfolge des Eingangs.
    private(set) var pending: [Command] = []
    private var attachedCount = 0

    /// `true`, solange ein Editor mit diesem Objekt im Environment sichtbar ist.
    /// Eignet sich, um ein externes Menue zu sperren.
    public var isAttached: Bool { attachedCount > 0 }

    public init() {}

    /// Rueckt den Quelltext ein (wie „Formatieren“ im Werkzeug-Menue).
    public func format() { send(.format) }

    /// Kopiert den vollstaendigen Quelltext (inklusive Base64) in die Zwischenablage.
    public func copyCode() { send(.copyCode) }

    /// Leert den Quelltext.
    public func clear() { send(.clear) }

    private func send(_ command: Command) {
        guard isAttached else { return }
        pending.append(command)
    }

    func attach() { attachedCount += 1 }

    func detach() {
        attachedCount = max(0, attachedCount - 1)
        if attachedCount == 0 { pending = [] }
    }

    /// Liefert die ausstehenden Aktionen und leert die Warteschlange.
    func takeAll() -> [Command] {
        defer { pending = [] }
        return pending
    }
}

extension EnvironmentValues {
    /// Aktions-Kanal fuer den `TypstEditor`; `nil`, solange die App keinen setzt.
    @Entry public var typstEditorActions: TypstEditorActions? = nil
}

// MARK: - Menue

/// Das Werkzeug-Menue des Editors als eigenstaendiger Knopf — dieselben Eintraege
/// wie im Toolbar-Menue des `TypstEditor`: zuerst `extraMenuItems`, dann
/// „Formatieren“, „Code kopieren“ und „Code leeren“, die ueber `actions` am
/// angebundenen Editor ausgefuehrt werden. Ohne angebundenen Editor ist der
/// Knopf deaktiviert.
public struct TypstEditorToolsMenu<ExtraMenu: View>: View {
    private let actions: TypstEditorActions
    private let extraMenuItems: () -> ExtraMenu

    /// - Parameters:
    ///   - actions: Kanal zum Editor (derselbe wie in `\.typstEditorActions`)
    ///   - extraMenuItems: App-Eintraege oberhalb der Code-Werkzeuge
    public init(
        actions: TypstEditorActions,
        @ViewBuilder extraMenuItems: @escaping () -> ExtraMenu
    ) {
        self.actions = actions
        self.extraMenuItems = extraMenuItems
    }

    public var body: some View {
        TypstEditorToolsMenuButton(
            format: actions.format,
            copyCode: actions.copyCode,
            clear: actions.clear,
            extraMenuItems: extraMenuItems
        )
        .disabled(!actions.isAttached)
    }
}

extension TypstEditorToolsMenu where ExtraMenu == EmptyView {
    public init(actions: TypstEditorActions) {
        self.init(actions: actions, extraMenuItems: { EmptyView() })
    }
}

/// Gemeinsamer Aufbau fuer das Toolbar-Menue des Editors und `TypstEditorToolsMenu`.
struct TypstEditorToolsMenuButton<ExtraMenu: View>: View {
    let format: () -> Void
    let copyCode: () -> Void
    let clear: () -> Void
    let extraMenuItems: () -> ExtraMenu

    var body: some View {
        Menu {
            // App-spezifische Menuepunkte (Snippets, Bildimport, KI ...)
            extraMenuItems()

            Divider()

            Button(action: format) {
                Label("Formatieren", systemImage: "wand.and.stars")
            }

            Button(action: copyCode) {
                Label("Code kopieren", systemImage: "doc.on.doc")
            }

            Divider()

            Button(role: .destructive, action: clear) {
                Label("Code leeren", systemImage: "trash")
            }
        } label: {
            Label("Typst-Werkzeuge", systemImage: "wand.and.stars.inverse")
        }
    }
}
