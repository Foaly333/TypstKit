//
//  FlagKontrakt.swift
//  TypstCompilerKit
//
//  Flag-Kontrakt v1 zwischen Typst-Dokumenten und der App:
//  - Hinkanal:  Input-Flags via sys.inputs (kompiliereMitFlags(inputs:))
//  - Rückkanal: Output-Flags via metadata unter dem Label <mo-element>,
//    extrahiert im selben Kompilierlauf (MoAusgabe).
//
//  Strikte Additivität (E5): NativeTypstCompilerProtocol erhält KEINE neuen
//  Requirements — kompiliereMitFlags ist eine Protocol-Extension mit
//  Default-Implementierung; bestehende Konformer (Mocks!) bleiben gültig.
//

import Foundation

// MARK: - JSON-Werttyp

/// Ein JSON-fähiger Wert aus einer `mo-melde`-Payload.
/// Der Kontrakt erlaubt nur str/int/float/bool/null/array/object.
public nonisolated enum MoJSONWert: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case ganzzahl(Int)
    case zahl(Double)
    case text(String)
    case liste([MoJSONWert])
    case objekt([String: MoJSONWert])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? container.decode(Int.self) {
            self = .ganzzahl(i)
        } else if let d = try? container.decode(Double.self) {
            self = .zahl(d)
        } else if let s = try? container.decode(String.self) {
            self = .text(s)
        } else if let a = try? container.decode([MoJSONWert].self) {
            self = .liste(a)
        } else if let o = try? container.decode([String: MoJSONWert].self) {
            self = .objekt(o)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Kein JSON-fähiger Wert"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let b): try container.encode(b)
        case .ganzzahl(let i): try container.encode(i)
        case .zahl(let d): try container.encode(d)
        case .text(let s): try container.encode(s)
        case .liste(let a): try container.encode(a)
        case .objekt(let o): try container.encode(o)
        }
    }

    // Bequeme Zugriffe für typische Payload-Felder.

    /// String-Wert, falls `.text`.
    public var textWert: String? {
        if case .text(let s) = self { return s } else { return nil }
    }

    /// Int-Wert; `.zahl` wird verlustfrei konvertiert, falls möglich.
    public var ganzzahlWert: Int? {
        switch self {
        case .ganzzahl(let i): return i
        case .zahl(let d) where d == d.rounded(): return Int(d)
        default: return nil
        }
    }

    /// Double-Wert, falls `.zahl` oder `.ganzzahl`.
    public var zahlWert: Double? {
        switch self {
        case .zahl(let d): return d
        case .ganzzahl(let i): return Double(i)
        default: return nil
        }
    }

    /// Bool-Wert, falls `.bool`.
    public var boolWert: Bool? {
        if case .bool(let b) = self { return b } else { return nil }
    }

    /// Listen-Wert, falls `.liste`.
    public var listeWert: [MoJSONWert]? {
        if case .liste(let a) = self { return a } else { return nil }
    }

    /// Objekt-Wert, falls `.objekt`.
    public var objektWert: [String: MoJSONWert]? {
        if case .objekt(let o) = self { return o } else { return nil }
    }
}

// MARK: - Output-Flag

/// Ein vom Dokument gemeldetes Output-Flag (Flag-Kontrakt v1).
public nonisolated struct MoAusgabe: Codable, Sendable, Equatable {
    /// Meldungstyp, z. B. "timer", "quiz", "kann"
    public let typ: String
    /// JSON-Payload der Meldung
    public let daten: [String: MoJSONWert]
    /// Seitenindex, 0-basiert
    public let seite: Int
    /// X-Koordinate des Ankerpunkts in pt (Ursprung oben links der Seite)
    public let xPt: Double
    /// Y-Koordinate des Ankerpunkts in pt (Ursprung oben links der Seite)
    public let yPt: Double

    enum CodingKeys: String, CodingKey {
        case typ, daten, seite
        case xPt = "x_pt"
        case yPt = "y_pt"
    }

    public init(typ: String, daten: [String: MoJSONWert], seite: Int, xPt: Double, yPt: Double) {
        self.typ = typ
        self.daten = daten
        self.seite = seite
        self.xPt = xPt
        self.yPt = yPt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // typ kann laut Kontrakt null sein, wenn ein Dokument ohne
        // Dictionary-Struktur meldet — dann als leeren String behandeln.
        self.typ = try container.decodeIfPresent(String.self, forKey: .typ) ?? ""
        self.daten = try container.decodeIfPresent([String: MoJSONWert].self, forKey: .daten) ?? [:]
        self.seite = try container.decode(Int.self, forKey: .seite)
        self.xPt = try container.decode(Double.self, forKey: .xPt)
        self.yPt = try container.decode(Double.self, forKey: .yPt)
    }
}

// MARK: - Protocol-Extension (Default-Implementierung)

public extension NativeTypstCompilerProtocol {
    /// Kompiliert mit Input-Flags und liefert PDF + Output-Flags.
    /// Default: Fallback ohne Flags — bestehende Konformer (Mocks!) bleiben
    /// gültig und liefern ein leeres Ausgaben-Array.
    ///
    /// Wichtig: Da kein neues Protocol-Requirement existiert (E5), wird
    /// diese Methode statisch dispatcht. Damit Aufrufe über
    /// `any NativeTypstCompilerProtocol` (z. B. aus dem Environment) trotzdem
    /// den echten FFI-Pfad erreichen, prüft der Default explizit auf
    /// `NativeTypstCompiler` und delegiert dorthin.
    nonisolated func kompiliereMitFlags(
        source: String,
        packageFiles: [PackageFile],
        imageFiles: [ImageFile],
        inputs: [String: String]
    ) async throws -> (pdf: Data, ausgaben: [MoAusgabe]) {
        if let nativ = self as? NativeTypstCompiler {
            return try await nativ.kompiliereMitFlags(
                source: source,
                packageFiles: packageFiles,
                imageFiles: imageFiles,
                inputs: inputs
            )
        }
        let pdf = try await compileToPDF(source: source, packageFiles: packageFiles, imageFiles: imageFiles)
        return (pdf, [])
    }
}

// MARK: - Echte FFI-Implementierung

extension NativeTypstCompiler {
    /// Kompiliert mit Input-Flags über die native FFI-Funktion
    /// `compile_to_pdf_with_flags` — PDF und Output-Flags entstehen im
    /// selben Kompilierlauf (kein zweites Kompilieren).
    public nonisolated func kompiliereMitFlags(
        source: String,
        packageFiles: [PackageFile],
        imageFiles: [ImageFile],
        inputs: [String: String]
    ) async throws -> (pdf: Data, ausgaben: [MoAusgabe]) {
        let fontData = self.fontData
        do {
            let result = try await Self.runOnCompileQueue {
                try compileToPdfWithFlags(
                    source: source,
                    fontData: fontData,
                    packageFiles: packageFiles,
                    imageFiles: imageFiles,
                    inputs: inputs
                )
            }
            let ausgaben = try JSONDecoder().decode(
                [MoAusgabe].self,
                from: Data(result.ausgabenJson.utf8)
            )
            return (result.pdf, ausgaben)
        } catch let error as TypstCompilationError {
            throw error.toNativeError()
        }
    }
}

// MARK: - Gebündeltes mo-tools-Paket

/// Stellt das gebündelte Typst-Paket `mo-tools` als `[PackageFile]` bereit.
///
/// Opt-in (E5.3): TypstKit hängt das Paket NIE automatisch an Kompilierläufe
/// an — die App gibt `MoToolsPackage.files` explizit als `packageFiles` mit
/// und importiert im Dokument `@local/mo-tools:0.1.0`.
public nonisolated enum MoToolsPackage {
    /// Paket-Namespace (Import: `@local/mo-tools:0.1.0`)
    public static let namespace = "local"
    /// Paket-Name
    public static let name = "mo-tools"
    /// Paket-Version
    public static let version = "0.1.0"
    /// Import-Zeile für Typst-Dokumente
    public static let importZeile = "#import \"@local/mo-tools:0.1.0\": *"

    /// Die Paketdateien im selben Format wie `additionalPackageFiles`.
    /// Es werden nur die vom Compiler benötigten Dateien geliefert
    /// (typst.toml + *.typ, ohne probe.typ/install.sh/README).
    public static var files: [PackageFile] {
        guard let baseURL = Bundle.module.url(forResource: "mo-tools", withExtension: nil) else {
            return []
        }
        let dateinamen = ["typst.toml", "lib.typ", "kontrakt.typ", "elemente.typ"]
        var files: [PackageFile] = []
        for name in dateinamen {
            let url = baseURL.appendingPathComponent(name)
            guard let content = try? Data(contentsOf: url) else { continue }
            files.append(PackageFile(
                namespace: namespace,
                name: Self.name,
                version: version,
                path: name,
                content: content
            ))
        }
        return files
    }
}
