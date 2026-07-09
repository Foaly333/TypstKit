# Arbeitsauftrag: Base64-Bilder auf den Asset-Store umstellen

Diese Anleitung richtet sich an einen KI-Agenten, der **im App-Projekt** arbeitet
(nicht im TypstKit-Paket). TypstKit ist eine Abhängigkeit und wird hier **nicht**
verändert.

---

## 1. Ausgangslage

Typst-Dokumente der App enthalten Bilder als Base64-Text, direkt im Quelltext:

```typst
#let imageObjectsFirstCode = "iVBORw0KGgoAAAANSUhEUg…"     // ~140.000 Zeichen
#let imageObjectsFirst = image(base64.decode(imageObjectsFirstCode))
```

Das ist die Ursache des RAM-Problems auf dem iPad. Dasselbe Bild existiert
gleichzeitig als Editor-String, als Masking-Mapping, als UTF-8-Kopie im
UniFFI-Puffer, als geparster `Source` in Rust, als `Str`-Wert im
`comemo`-Cache, als dekodierte Bytes und als Raster.

Weil der Quelltext so groß ist, existiert im Editor bereits eine Maskierung
(`extractBase64Tokens`, `restoreBase64`, `tokenizedToDisplay`), die den Base64
durch `"[Bild 1 — Base64 ausgeblendet]"` ersetzt. Diese Maskierung ist ein
Symptom, keine Lösung — sie fällt am Ende weg.

## 2. Zielzustand

Im Dokument steht nur noch ein Pfad; das Bild liegt einmal auf der Platte:

```typst
#let imageObjectsFirstCode = "img/3f2a…b7.png"
#let imageObjectsFirst = image(imageObjectsFirstCode)
```

Aus ~141.000 Zeichen werden ~90. Der `TypstImageResolver` löst `img/…`-Pfade
auf — sowohl direkt in `image("…")` als auch über die `#let`-Bindung, die der
Importer erzeugt. An ihm ist nichts zu ändern.

> Das gilt **ab TypstKit 0.1.5**. Ältere Versionen erkennen nur
> `image("img/…")` und melden für importierte Dokumente
> `file not found (searched at img/…)`.

Beim Export (Teilen, Zwischenablage) wird der Base64 wieder eingebettet, sodass
der Quelltext selbstenthaltend bleibt und in einem externen Editor bearbeitet
werden kann.

---

## 3. Verfügbare API (`import TypstAssetKit`)

Wird über `TypstCompilerKit` mit re-exportiert. Alle Typen sind `nonisolated`.

### Store

```swift
struct TypstAssetStore: Sendable {
    init(root: URL)                                     // img/ liegt unter root
    func store(data: Data) throws -> TypstAssetRef
    func data(for ref: TypstAssetRef) throws -> Data
    func url(for ref: TypstAssetRef) -> URL
    func contains(_ ref: TypstAssetRef) -> Bool
    func allAssets() throws -> Set<TypstAssetRef>
    @discardableResult
    func collectGarbage(referenced: Set<TypstAssetRef>) throws -> [TypstAssetRef]
}

struct TypstAssetRef: Hashable, Sendable {
    init?(path: String)          // "img/<32 hex>.<ext>"
    var path: String
    var hash: String
    var format: TypstImageFormat // png, jpeg, gif, webp, svg, pdf
}
```

### Import (Base64 → Store)

```swift
enum TypstDocumentImporter {
    static func importSource(
        _ source: String,
        store: TypstAssetStore,
        syntax: TypstInlineImageSyntax = .default
    ) throws -> (source: String, summary: TypstImportSummary)

    @discardableResult
    static func importFileInPlace(
        at url: URL,
        store: TypstAssetStore,
        syntax: TypstInlineImageSyntax = .default,
        backupDirectory: URL? = nil
    ) throws -> TypstImportSummary
}

struct TypstImportSummary: Sendable {
    let assets: [TypstAssetRef]   // alle referenzierten Bilder (neu + vorhanden)
    let didChange: Bool           // false = war schon importiert
}
```

`importFileInPlace` schreibt erst vollständig in eine Nachbardatei und ersetzt
das Original nur bei Erfolg. Bei einem Fehler bleibt das Original unangetastet.

### Export (Store → Base64)

```swift
enum TypstDocumentExporter {
    static func exportToString(
        source: String,
        store: TypstAssetStore,
        syntax: TypstInlineImageSyntax = .default
    ) throws -> String

    @discardableResult
    static func exportFile(
        source: String,
        store: TypstAssetStore,
        to url: URL,
        syntax: TypstInlineImageSyntax = .default
    ) throws -> Int

    static func assetReferences(in source: String) -> Set<TypstAssetRef>
}
```

### Fehler

```swift
enum TypstImportError: Error, Equatable {
    case unterminatedString(offset: Int)
    case malformedDecodeCall(offset: Int)   // decode-Aufruf ohne ')'
}

enum TypstAssetError: Error, Equatable {
    case unsupportedFormat
    case missingAsset(String)
    case invalidAssetPath(String)
}
```

---

## 4. Arbeitsschritte

**Reihenfolge einhalten.** Schritt 4 darf erst nach 1–3 erfolgen.

### Schritt 1 — Store zentral bereitstellen

Die Store-Wurzel **muss** exakt das Verzeichnis sein, in dem
`TypstImageResolver` nach `img/…` sucht. Der Resolver versucht zuerst den
iCloud-Container, dann den lokalen Cache:

- iCloud: `url(forUbiquityContainerIdentifier:)` + `Documents`
- Fallback: `Application Support/<cacheDirectoryName>`
  (Standard: `TypstImageCache`)

Lege genau eine Stelle an, die den Store liefert, und leite sie aus derselben
`TypstImageResolverConfiguration` ab, die die App schon an den
`NativeTypstController` übergibt. Es darf keine zweite, abweichende
Container-ID im Code stehen.

Wenn iCloud nicht verfügbar ist, muss der Store auf das Cache-Verzeichnis
zeigen — sonst schreibt der Importer irgendwohin, wo der Resolver nicht sucht.

### Schritt 2 — Import beim Laden eines Dokuments

Finde die Stelle, an der ein Dokument geladen und sein Quelltext das erste Mal
gesetzt wird. Dort läuft der Import — **vor** dem ersten Compile und **vor**
dem Setzen des Editor-Texts.

- Liegen Dokumente als `.typ`-Dateien vor: `importFileInPlace(at:store:backupDirectory:)`.
  Setze `backupDirectory` auf einen App-internen Ordner. Das Original bleibt
  dort, bis der erste erfolgreiche Compile durch ist.
- Liegen Dokumente als String in SwiftData/Core Data: `importSource(_:store:)`,
  Ergebnis zurückschreiben. Nur speichern, wenn `summary.didChange == true`.

Beachte:

- **Nicht auf dem Main-Actor.** Der Import ist synchron und kann bei einem
  Bestandsdokument mehrere hundert Millisekunden dauern. Über `Task.detached`
  oder eine dedizierte Queue aufrufen.
- **iCloud-Dateien anstoßen.** Vor dem Lesen
  `FileManager.default.startDownloadingUbiquitousItem(at:)` aufrufen, wie es
  `TypstImageResolver.processLocalRef` bereits tut.
- **Fehler abfangen.** Wirft der Import (`malformedDecodeCall`,
  `unterminatedString`), das Dokument unverändert lassen, den Fehler loggen und
  normal weiterarbeiten. Nicht abstürzen, nicht leeren Text setzen.
- **Idempotenz nutzen.** Der Importer erkennt bereits importierte Dokumente und
  meldet `didChange == false`. Es braucht kein eigenes Migrations-Flag.
- Der Import ist **dauerhaft** nötig, nicht nur zur Migration: er ist auch der
  Pfad für Quelltext, den der Nutzer von außen einfügt.

### Schritt 3 — Export

Ergänze eine Aktion „Quelltext kopieren" bzw. „Quelltext exportieren", die
`exportToString(source:store:)` bzw. `exportFile(source:store:to:)` aufruft.

Das Ergebnis ist selbstenthaltend und kann in einem externen Editor bearbeitet
und über Schritt 2 wieder eingelesen werden.

`exportToString` erzeugt den großen String zwangsläufig im Speicher — das ist
für die Zwischenablage unvermeidbar. Für „In Datei sichern" **immer**
`exportFile` benutzen, das streamt.

Der Export erzeugt eine kanonische Form:

```typst
#let imageObjectsFirstCode = base64.decode("iVBOR…")
#let imageObjectsFirst = image(imageObjectsFirstCode)
```

Semantisch identisch zum Ausgangsdokument, aber normalisiert. Ab dann gilt
exakt `import(export(d)) == d` und `export(import(c)) == c`.

Fehlt die Zeile `#import "@preview/based:0.2.0": base64`, ergänzt der Export sie.

### Schritt 4 — Maskierung zurückbauen (erst jetzt)

Wenn 1–3 stehen und ein Bestandsdokument nachweislich migriert wurde, wird die
Base64-Maskierung in TypstKit arbeitslos. Sie zu entfernen ist eine Änderung
**an TypstKit**, nicht an der App — also nicht Teil dieses Auftrags. Melde
stattdessen zurück, dass folgende Symbole entfernt werden können:

- `TypstEditor.swift`: `rawTextWithTokens`, `base64Mapping` und die
  Token-Konvertierungen im `text`-Binding
- `TypstEditorController.swift`: `extractBase64Tokens`, `restoreBase64`,
  `tokenizedToDisplay`, `displayToTokenized`, `base64Regex`,
  `base64LetAssignmentRegex`, `tokenPrefix`

Damit verschwindet auch der teure Binding-Getter, der `restoreBase64` bei jeder
SwiftUI-Body-Auswertung aufruft.

### Schritt 5 — Garbage Collection

Bilder werden über Dokumente hinweg dedupliziert (inhaltsadressiert). Ein Asset
darf deshalb erst gelöscht werden, wenn **kein** Dokument es mehr referenziert:

```swift
var referenced: Set<TypstAssetRef> = []
for source in alleDokumentQuelltexte {
    referenced.formUnion(TypstDocumentExporter.assetReferences(in: source))
}
try store.collectGarbage(referenced: referenced)
```

Nur aufrufen, wenn wirklich alle Dokumente eingelesen sind. Eine unvollständige
Menge löscht Bilder, die noch gebraucht werden. Im Zweifel gar nicht aufrufen —
verwaiste Bilder sind harmlos, gelöschte nicht.

---

## 5. Abnahmekriterien

1. Ein Bestandsdokument mit eingebettetem Bild öffnen. Danach enthält der
   Quelltext `img/<hash>.png` und keinen Base64 mehr. Die Zeichenzahl fällt von
   ~141.000 auf ~90.
2. Die PDF-Vorschau zeigt dasselbe Bild wie vorher.
3. Dasselbe Dokument erneut öffnen: `didChange == false`, keine Schreibvorgänge.
4. Export → Ergebnis in einen Texteditor kopieren → wieder in die App einfügen:
   identisches Bild, identischer Hash.
5. Ein Dokument ohne Bilder öffnen: Byte-identisch, keine Schreibvorgänge.
6. Zwei Dokumente mit demselben Bild: genau eine Datei unter `img/`.
7. Ein Dokument mit einem Base64-String, der kein Bild ist (z.B. eingebettete
   Schriftdaten): bleibt unverändert.

## 6. Fallstricke

- **Store-Wurzel und Resolver-Wurzel müssen übereinstimmen.** Der häufigste
  Fehler. Symptom: Import läuft durch, Bild wird beim Compile nicht gefunden.
- **Import nicht im `body` oder in einem Binding-Getter aufrufen.** Nur einmal
  beim Laden.
- **`.typ`-Dateien sind nach dem Import nicht mehr selbstenthaltend.** Wer das
  Dokument aus der App heraus teilt, muss den Export benutzen — nicht die
  Rohdatei kopieren.
- **`minimumBase64Length` nicht senken.** Der Standard (200) verhindert, dass
  kurze Strings fälschlich als Bilddaten gelten.
- **TypstKit nicht anfassen.** Alle Änderungen gehören in die App.
