# TypstKit

Nativer Typst-Compiler (Rust via UniFFI) und Editor-UI als wiederverwendbares Swift-Paket für **iOS 26+ und macOS 26+**.

Kein Server-Roundtrip, kein WebView: Typst-Quelltext wird direkt auf dem Gerät zu PDF oder SVG kompiliert.

## Features

- **Native Kompilierung** zu PDF und/oder SVG über eine in Rust geschriebene, per UniFFI angebundene Typst-Engine
- **Fertige Editor-UI** mit Split-View, Syntax-Highlighting und Live-Vorschau
- **Automatische Package-Auflösung**: `#import`-Direktiven werden erkannt, aus der offiziellen Typst-Registry geladen und lokal gecacht (inklusive transitiver Abhängigkeiten)
- **Bildauflösung** für lokale Dateien, iCloud-Container und Web-URLs, direkt aus dem Quelltext heraus
- **Eingebettete Standardschriften** (Libertinus Serif, New Computer Modern/NCM Math, DejaVu Sans Mono) — Math-Modus und SVG-Export funktionieren ohne jede Font-Konfiguration
- **Dependency Injection** an allen relevanten Stellen, damit sich das Paket ohne Änderungen am Kern in unterschiedliche Apps einbetten lässt

## Produkte

| Produkt | Inhalt | Plattformen |
|---|---|---|
| `TypstCompilerKit` | FFI-Bindings, `NativeTypstCompiler`, `TypstPackageManager` (Registry-Downloads), `TypstImageResolver`, `NativeTypstController` | iOS + macOS |
| `TypstEditorKit` | `TypstEditor`, `NativeTypstEditorView` (Split-View mit Vorschau), `NativeTypstRenderView`, `NativeTypstPDFPreview` | iOS + macOS |

## Voraussetzungen

- Xcode mit Swift 6.2 Toolchain
- Deployment-Target iOS 26+ bzw. macOS 26+
- Rust-Toolchain nur, wenn das XCFramework neu gebaut werden soll (siehe unten) — für die reine Nutzung des Pakets nicht nötig, sofern `Binaries/TypstNative.xcframework` bereits macOS-Slices enthält

## Installation

### XCFramework bauen (einmalig)

Das mitgelieferte `Binaries/TypstNative.xcframework` enthält standardmäßig nur iOS-Slices. Für macOS-Unterstützung und die eingebetteten Standardschriften einmal bauen:

```bash
cd TypstKit/rust
./build-xcframework.sh
```

Das Script baut alle Targets (iOS, Simulator, macOS arm64+x86_64), regeneriert die Swift-Bindings nach `Sources/TypstNativeBindings/` und den Header nach `Sources/TypstNativeFFI/include/`. Manuelle Nacharbeit ist nicht nötig (`Sendable+Bindings.swift` bleibt erhalten).

### Paket einbinden

In Xcode: **File > Add Package Dependencies > Add Local...** und den `TypstKit`-Ordner wählen. Anschließend die gewünschten Produkte (`TypstCompilerKit`, `TypstEditorKit`) dem Target hinzufügen.

Das Paket kann jederzeit im Dateisystem verschoben werden — die lokale Referenz in Xcode muss dann entsprechend neu gesetzt werden.

## Schnellstart

```swift
import SwiftUI
import TypstCompilerKit
import TypstEditorKit

struct ContentView: View {
    @State private var code = AttributedString("= Hallo Typst\n\n$ integral_0^1 x^2 dif x $")

    var body: some View {
        NavigationStack {
            NativeTypstEditorView(text: $code, compiler: NativeTypstCompiler())
        }
    }
}
```

Ohne Editor-UI, nur Kompilierung:

```swift
import TypstCompilerKit

let controller = NativeTypstController(compiler: NativeTypstCompiler())
await controller.compile(source: myTypstSource) // myTypstSource: TypstProvidingProtocol
// controller.pdfDocument / controller.pdfData enthalten das Ergebnis
```

## Anpassungspunkte (Dependency Injection)

`NativeTypstController` nimmt alle app-spezifischen Belange per Initializer entgegen:

```swift
let controller = NativeTypstController(
    compiler: NativeTypstCompiler(),
    // iCloud-Container für lokale img/-Bilder:
    imageResolverConfiguration: TypstImageResolverConfiguration(
        ubiquityContainerIdentifier: "iCloud.dk.materialOrganizer",
        cacheDirectoryName: "TypstTemplateCache"
    ),
    // Lokale #import-Dateien (z.B. aus einem app-eigenen Template-Store):
    additionalPackageFiles: { TypstTemplateStore.shared.localPackageFiles },
    // Eigene Dateinamens-Logik für den PDF-Export:
    exportFileNamer: { FileNameService().sanitized($0, extension: "pdf") }
)
```

`NativeTypstEditorView` akzeptiert diesen Controller sowie:

- `sourceBuilder: (String) -> any TypstProvidingProtocol` — baut aus dem Editor-Klartext den kompilierbaren Quelltext (Header, Snippet-Präfixe etc.)
- `extraMenuItems` — zusätzliche Menüpunkte im Werkzeug-Menü (z.B. Snippets, Bildimport, KI-Generierung)
- `autoCompile: Binding<Bool>?` — externer Zustand; ohne Binding wird intern AppStorage (`TypstKit.autoCompile`) verwendet

Snippet- und Bildimport-Einfügungen laufen über das `text`-Binding: externe Änderungen übernimmt der Editor automatisch (inklusive Base64-Maskierung).

Eigene Datenmodelle binden sich über `TypstProvidingProtocol` an den Compiler an — eine Konformanz reicht, um beliebige App-Objekte kompilierbar zu machen.

## Eingebettete Schriften (Math-Modus & SVG)

Die Rust-Binary bettet die Typst-Standardschriften ein (Cargo-Feature `embed-fonts`, standardmäßig aktiv): **Libertinus Serif** (Text), **New Computer Modern / NCM Math** (Math-Modus), **DejaVu Sans Mono** (Code). Damit funktionieren Math-Modus und SVG-Export ohne jede Font-Konfiguration.

Zusätzliche Schriften lassen sich entweder als Bundle-Ressourcen in einem `Fonts/`-Ordner einbinden (`NativeTypstCompiler(bundle:fontDirectoryName:)`) oder automatisch über den CoreText-System-Fallback auflösen.

## Architektur

```
TypstNative.xcframework (binaryTarget, Rust-dylib)
        ▲ (Symbole zur Link-Zeit)
TypstNativeFFI (C-Target: Header als Clang-Modul)
        ▲
TypstNativeBindings (UniFFI-generiert, OHNE MainActor-Default)
        ▲ (@_exported)
TypstCompilerKit (MainActor-Default, Approachable Concurrency)
        ▲
TypstEditorKit
```

Die Trennung der Bindings in ein eigenes Target ohne MainActor-Default-Isolation erlaubt es, den UniFFI-Output unverändert zu übernehmen — nach einer Regenerierung sind keine manuellen `nonisolated`-Patches nötig.

## In ein bestehendes Projekt integrieren

1. Paket einbinden (siehe oben), `import TypstCompilerKit` bzw. `import TypstEditorKit` in den betroffenen Dateien ergänzen.
2. Eine eventuell bereits vorhandene, app-eigene Typst-Integration (Compiler-Wrapper, Package-Manager, Bildauflösung, Editor-View) durch die Produkte dieses Pakets ersetzen und die alten Dateien entfernen.
3. Eigene Datenmodelle per `TypstProvidingProtocol`-Konformanz anbinden; app-spezifische Belange (Bildquellen, Template-Store, Dateinamensvergabe) über die Initializer von `NativeTypstController` und `NativeTypstEditorView` injizieren (siehe [Anpassungspunkte](#anpassungspunkte-dependency-injection)).
4. Menüpunkte, Snippets und KI-Funktionen bleiben Sache der App und werden über `extraMenuItems` in die Editor-UI eingehängt.

## Später: Verteilung ohne lokalen Pfad

Wenn die API stabil ist, kann das Paket in ein eigenes Git-Repository überführt werden. Das XCFramework lässt sich dann als Zip an einen GitHub-Release anhängen (`binaryTarget(url:checksum:)`), sodass konsumierende Projekte konkrete Versionen pinnen können, statt eine lokale Pfad-Referenz zu nutzen.
