//
//  TypstEditorInsertion.swift
//  TypstEditorKit
//
//  Kanal, ueber den eine App Code an der Cursorposition des Editors einfuegt
//  (z. B. ein Bild aus einem Import-Sheet). Die Selektion bleibt privat im
//  Editor; die App setzt nur den Kanal ins Environment.
//

import SwiftUI

/// Nimmt Code entgegen, den der `TypstEditor` im Environment an der Cursorposition
/// einfuegt. Hatte der Editor noch nie den Fokus, wird ans Ende angehaengt.
///
/// ```swift
/// @State private var einfuegung = TypstEditorInsertion()
/// TypstEditor(text: $text) { … }
///     .environment(\.typstEditorInsertion, einfuegung)
/// // spaeter:
/// einfuegung.insert("#image(\"img/…\")")
/// ```
@Observable
public final class TypstEditorInsertion {
    /// Noch nicht uebernommener Code, in Reihenfolge des Eingangs.
    public private(set) var pending: [String] = []

    public init() {}

    public func insert(_ code: String) {
        pending.append(code)
    }

    /// Liefert den ausstehenden Code und leert die Warteschlange.
    func takeAll() -> [String] {
        defer { pending = [] }
        return pending
    }
}

extension EnvironmentValues {
    /// Einfuege-Kanal fuer den `TypstEditor`; `nil`, solange die App keinen setzt.
    @Entry public var typstEditorInsertion: TypstEditorInsertion? = nil
}
