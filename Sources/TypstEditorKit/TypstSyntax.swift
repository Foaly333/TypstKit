//
//  TypstSyntax.swift
//  TypstEditorKit
//
//  Attribut-Definitionen fuer das Syntax-Highlighting des Typst-Editors.
//

import SwiftUI

/// Preference-Key, ueber den der Editor die aktuelle Textauswahl nach oben meldet.
public struct TypstCodePreferenceKey: PreferenceKey {
    public nonisolated(unsafe) static var defaultValue: AttributedString = ""

    public static func reduce(value: inout AttributedString, nextValue: () -> AttributedString) {
        value = value + nextValue()
    }
}

/// Custom-Attribut, das Typst-Syntax-Elemente (z.B. #-Woerter) markiert.
public struct TypstCodeAttribute: CodableAttributedStringKey {
    public typealias Value = String

    public static let name = "TypstEditorKit.TypstCodeAttribute"
}

extension AttributeScopes {
    /// Attribut-Scope fuer die vom TypstEditorKit definierten Custom-Attribute.
    public struct TypstEditorAttributes: AttributeScope {
        public let typstCode: TypstCodeAttribute
    }
}

/// Formatting-Definition: faerbt markierte Typst-Syntax ein.
public struct TypstCodeFormattingDefinition: AttributedTextFormattingDefinition {
    public struct Scope: AttributeScope {
        public let foregroundColor: AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute
        public let adaptiveImageGlyph: AttributeScopes.SwiftUIAttributes.AdaptiveImageGlyphAttribute
        public let typstCode: TypstCodeAttribute
    }

    public init() {}

    public var body: some AttributedTextFormattingDefinition<Scope> {
        TypstHashWordConstraint()
    }
}

/// Constraint: Woerter mit Typst-Code-Attribut werden lila eingefaerbt.
public struct TypstHashWordConstraint: AttributedTextValueConstraint {
    public typealias Scope = TypstCodeFormattingDefinition.Scope
    public typealias AttributeKey = AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute

    public init() {}

    public func constrain(_ container: inout Attributes) {
        if container.typstCode != nil {
            container.foregroundColor = .purple
        } else {
            container.foregroundColor = nil
        }
    }
}

extension AttributeDynamicLookup {
    /// Subscript, das die Custom-Attribute in den Dynamic-Attribute-Lookup einbindet.
    /// Dadurch ist z.B. `attributedString.typstCode` verfuegbar.
    public subscript<T: AttributedStringKey>(
        dynamicMember keyPath: KeyPath<AttributeScopes.TypstEditorAttributes, T>
    ) -> T {
        self[T.self]
    }
}
