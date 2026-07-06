# TypstKit

Nativer Typst-Compiler (Rust via UniFFI) und Editor-UI als wiederverwendbares Swift-Paket für **iOS 26+ und macOS 26+**.

## Produkte

| Produkt | Inhalt | Plattformen |
|---|---|---|
| `TypstCompilerKit` | FFI-Bindings, `NativeTypstCompiler`, `TypstPackageManager` (Registry-Downloads), `TypstImageResolver`, `NativeTypstController` | iOS + macOS |
| `TypstEditorKit` | `TypstEditor`, `NativeTypstEditorView` (Split-View mit Vorschau), `NativeTypstRenderView`, `NativeTypstPDFPreview` | iOS + macOS |

## Erste Schritte

### 1. XCFramework bauen (einmalig, auf dem Mac)

Das mitgelieferte `Binaries/TypstNative.xcframework` enthält nur iOS-Slices.
Für macOS-Unterstützung und die **eingebetteten Standard-Schriften** einmal neu bauen:

```bash
cd TypstKit/rust
./build-xcframework.sh
```

Das Script baut alle Targets (iOS, Simulator, macOS arm64+x86_64), regeneriert
die Swift-Bindings nach `Sources/TypstNativeBindings/` und den Header nach
`Sources/TypstNativeFFI/include/`. Manuelle Nacharbeit ist nicht nötig
(`Sendable+Bindings.swift` bleibt erhalten).

### 2. Paket einbinden (Weg 1: lokales Paket)

In Xcode: **File > Add Package Dependencies > Add Local...** und den
`TypstKit`-Ordner wählen. Dann die gewünschten Produkte zum Target hinzufügen.

Das Paket kann jederzeit aus dem Projektordner heraus neben die Projekte
verschoben werden (z.B. `App-Projekte/TypstKit`) — die lokale Referenz in
Xcode entsprechend neu setzen.

### 3. Minimales Beispiel

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

## Eingebettete Schriften (Math-Modus & SVG)

Die Rust-Binary bettet die Typst-Standardschriften ein (Cargo-Feature
`embed-fonts`, standardmäßig aktiv): **Libertinus Serif** (Text),
**New Computer Modern / NCM Math** (Math-Modus), **DejaVu Sans Mono** (Code).
Damit funktionieren Math-Modus und SVG-Export ohne jede Font-Konfiguration.

Zusätzliche Schriften: entweder als Bundle-Ressourcen in einem `Fonts/`-Ordner
(`NativeTypstCompiler(bundle:fontDirectoryName:)`) oder automatisch über den
CoreText-System-Fallback.

## Anpassungspunkte (Dependency Injection)

`NativeTypstController` nimmt alle app-spezifischen Belange per Initializer:

```swift
let controller = NativeTypstController(
    compiler: NativeTypstCompiler(),
    // iCloud-Container fuer lokale img/-Bilder:
    imageResolverConfiguration: TypstImageResolverConfiguration(
        ubiquityContainerIdentifier: "iCloud.dk.materialOrganizer",
        cacheDirectoryName: "TypstTemplateCache"
    ),
    // Lokale #import-Dateien (z.B. aus einem Template-Store):
    additionalPackageFiles: { TypstTemplateStore.shared.localPackageFiles },
    // Eigene Dateinamens-Logik:
    exportFileNamer: { FileNameService().sanitized($0, extension: "pdf") }
)
```

`NativeTypstEditorView` akzeptiert diesen Controller sowie:

- `sourceBuilder: (String) -> any TypstProvidingProtocol` — baut aus dem
  Editor-Klartext den kompilierbaren Quelltext (Header, Snippet-Präfixe etc.)
- `extraMenuItems` — zusätzliche Menüpunkte im Werkzeug-Menü
  (Snippets, Bildimport, KI-Generierung)
- `autoCompile: Binding<Bool>?` — externer Zustand; ohne Binding wird
  AppStorage (`TypstKit.autoCompile`) verwendet

Snippet-/Bildimport-Einfügungen funktionieren über das `text`-Binding:
externe Änderungen übernimmt der Editor automatisch (inkl. Base64-Maskierung).

## Migration aus MaterialOrganizer

1. Paket einbinden (beide Produkte), `import TypstCompilerKit` /
   `import TypstEditorKit` in den betroffenen Dateien ergänzen.
2. Diese App-Dateien löschen (jetzt im Paket):
   `NativeTypstCompiler.swift`, `NativeTypstCompilerProtocol.swift`,
   `TypstPackageManager.swift`, `TypstImageResolver.swift`,
   `NativeTypstController.swift`, `TypstEditorController.swift`,
   `TypstEditor.swift`, `NativeTypstEditorView.swift`,
   `NativeTypstPDFPreview.swift`, `NativeTypstRenderView.swift`,
   `TypstNativeBindings.swift`, `TypstNativeBindings/`-Ordner sowie die
   Framework-Referenz auf `Frameworks/TypstNative.xcframework`
   (das Paket bringt sein eigenes mit).
3. In der App bleiben: `TypstProvidingProtocol`-Konformanzen wie
   `DataObjectTypstProvider` (das Protokoll selbst kommt aus dem Paket),
   `TypstTemplateStore`, Snippets, Bildimport-Views, `GenerativeTypstViewModel`.
4. `NativeTypstEditorView`-Aufrufe anpassen: statt `scriptable:`-Init jetzt
   `sourceBuilder: { DataObjectTypstProvider(editedText: $0, scriptable: scriptable) }`;
   Snippet-Menü und KI-Button über `extraMenuItems` injizieren.
5. Der Attribut-Scope heißt jetzt `TypstEditorAttributes`
   (vorher `CustomAttributes`), das Attribut weiterhin `typstCode`.

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

Die Trennung der Bindings in ein eigenes Target ohne MainActor-Default-Isolation
erlaubt es, den UniFFI-Output unverändert zu übernehmen.

## Spätere Verteilung (Weg 2)

Wenn das API stabil ist: eigenes Git-Repo, XCFramework als Zip an
GitHub-Releases (`binaryTarget(url:checksum:)`), Projekte pinnen Versionen.
