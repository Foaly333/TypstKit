// swift-tools-version: 6.2
//
//  TypstKit — Nativer Typst-Compiler + Editor fuer iOS und macOS.
//
//  Produkte:
//  - TypstCompilerKit: FFI-Bindings, Compiler, Package-Manager, Bild-Aufloesung, Controller
//  - TypstEditorKit:   Editor-UI, PDF-Vorschau, Split-View (haengt von TypstCompilerKit ab)
//
//  Die Rust-Binary (TypstNative.xcframework) wird mit rust/build-xcframework.sh gebaut.
//

import PackageDescription

/// Gleiche Concurrency-Einstellungen wie in den konsumierenden App-Projekten:
/// Default Actor Isolation = MainActor + Approachable Concurrency.
let appIsolationSettings: [SwiftSetting] = [
    .defaultIsolation(MainActor.self),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
]

let package = Package(
    name: "TypstKit",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
    ],
    products: [
        .library(name: "TypstCompilerKit", targets: ["TypstCompilerKit"]),
        .library(name: "TypstEditorKit", targets: ["TypstEditorKit"]),
    ],
    targets: [
        // Vorkompilierte Rust-Binary (dynamisches Framework).
        // Enthaelt Slices fuer ios-arm64, ios-arm64-simulator und macos.
        .binaryTarget(
            name: "TypstNative",
            path: "Binaries/TypstNative.xcframework"
        ),

        // C-Shim: stellt den UniFFI-Header als importierbares Clang-Modul bereit,
        // damit `import TypstNativeFFI` in den generierten Bindings aufloest.
        // Die Symbole selbst liefert das TypstNative-Framework zur Link-Zeit.
        .target(
            name: "TypstNativeFFI",
            path: "Sources/TypstNativeFFI"
        ),

        // UniFFI-generierte Swift-Bindings.
        // Eigenes Target OHNE MainActor-Default-Isolation, damit der generierte
        // Code unveraendert kompiliert und nach einer Regenerierung
        // keine manuellen nonisolated-Patches noetig sind.
        .target(
            name: "TypstNativeBindings",
            dependencies: ["TypstNativeFFI", "TypstNative"],
            path: "Sources/TypstNativeBindings",
            swiftSettings: [
                // Swift-5-Modus: UniFFI-generierter Code enthaelt globalen
                // mutablen State (initializationResult), der unter Swift-6-
                // Strict-Concurrency nicht kompiliert.
                .swiftLanguageMode(.v5)
            ]
        ),

        // Compiler-Schicht: Font-Ladung, Package-Registry, Bild-Aufloesung,
        // @Observable-Controller mit Debouncing.
        .target(
            name: "TypstCompilerKit",
            dependencies: ["TypstNativeBindings"],
            path: "Sources/TypstCompilerKit",
            swiftSettings: appIsolationSettings
        ),

        // Editor-UI: Texteditor mit Syntax-Highlighting, PDF-Vorschau, Split-View.
        .target(
            name: "TypstEditorKit",
            dependencies: ["TypstCompilerKit"],
            path: "Sources/TypstEditorKit",
            swiftSettings: appIsolationSettings
        ),
    ]
)
