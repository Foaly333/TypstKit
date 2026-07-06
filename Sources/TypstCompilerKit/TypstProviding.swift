//
//  TypstProviding.swift
//  TypstCompilerKit
//
//  Protokoll fuer Typen, die Typst-Quelltext bereitstellen.
//  Ermoeglicht generische Kompilierung im NativeTypstController.
//

import Foundation

/// Protokoll fuer Typen, die kompilierbaren Typst-Quelltext liefern.
public nonisolated protocol TypstProvidingProtocol {
    var typst: String { get }
    /// Optionaler Titel fuer den PDF-Dateinamen beim Export
    var title: String { get }
}

// MARK: - String-Conformance

extension String: TypstProvidingProtocol {
    public nonisolated var typst: String { self }
    public nonisolated var title: String { "" }
}

// MARK: - PlainTypstProvider

/// Einfacher Provider aus Text + optionalem Praefix-Code (z.B. Snippet-Definitionen).
public struct PlainTypstProvider: TypstProvidingProtocol {
    public let title: String
    private let source: String
    private let prefix: String

    public init(text: String, prefix: String = "", title: String = "") {
        self.source = text
        self.prefix = prefix
        self.title = title
    }

    public var typst: String {
        prefix.isEmpty ? source : prefix + "\n" + source
    }
}
