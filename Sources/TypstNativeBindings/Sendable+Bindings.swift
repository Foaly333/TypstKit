//
//  Sendable+Bindings.swift
//  TypstNativeBindings
//
//  Sendable-Conformances fuer die UniFFI-generierten Typen.
//  Notwendig, weil die Typen ueber Modulgrenzen hinweg in
//  @concurrent-Funktionen verwendet werden (TypstCompilerKit).
//
//  Diese Datei wird von build-xcframework.sh NICHT ueberschrieben —
//  nur TypstNative.swift wird regeneriert.
//

// Reine Werttypen mit ausschliesslich Sendable-Feldern (String, Data, UInt32).
extension ImageFile: Sendable {}
extension PackageFile: Sendable {}
extension SourceDiagnostic: Sendable {}
extension TypstCompilationError: Sendable {}
