//
//  TypstImageResolverTests.swift
//  TypstCompilerKitTests
//
//  Deckt das Zusammenspiel ab: scannen → laden → nur die Literale ersetzen.
//  Der Lader wird injiziert, es geht kein Byte ins Netz.
//

import Foundation
import Testing

@testable import TypstCompilerKit

// MARK: - Testlader

/// Zaehlt Anfragen mit, damit „ein Download trotz zweier Fundstellen"
/// pruefbar ist.
private actor RequestLog {
    private(set) var urls: [URL] = []
    func record(_ url: URL) { urls.append(url) }
    var count: Int { urls.count }
}

private struct StubResponse {
    var statusCode: Int = 200
    var contentType: String?
    var data: Data
}

private func configuration(
    _ responses: [String: StubResponse],
    log: RequestLog? = nil
) -> TypstImageResolverConfiguration {
    TypstImageResolverConfiguration(
        localImagePrefix: "img/",
        loadWebResource: { url in
            await log?.record(url)
            guard let stub = responses[url.absoluteString] else {
                throw URLError(.fileDoesNotExist)
            }
            var headers: [String: String] = [:]
            if let contentType = stub.contentType { headers["Content-Type"] = contentType }
            let response = HTTPURLResponse(
                url: url,
                statusCode: stub.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!
            return (stub.data, response)
        }
    )
}

private let onePixelPNG = Data(
    base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
)!

private let htmlPage = Data(#"<!DOCTYPE html><html><body>Startseite</body></html>"#.utf8)

@Suite("Bildaufloesung schreibt nur Literale um")
struct TypstImageResolverTests {

    // MARK: Der Fehlerfall

    @Test("Ein Host im #let laesst Links im Fliesstext unangetastet")
    func leavesProseLinksAlone() async {
        let source = """
        #let host = "https://inf-schule.de"

        Quelle: https://inf-schule.de/awbs (16.4.1.1, Stand 08.07.2026)
        - *Mein erstes Programm* (2 Std., https://inf-schule.de/bjko): Einfuehrung
        """
        let log = RequestLog()
        let result = await TypstImageResolver.resolve(
            source: source,
            configuration: configuration(
                ["https://inf-schule.de": StubResponse(contentType: "text/html", data: htmlPage)],
                log: log
            )
        )

        #expect(result.resolvedSource == source)
        #expect(result.imageFiles.isEmpty)
        // Ein Host ohne Pfad wird gar nicht erst angefragt.
        #expect(await log.count == 0)
    }

    @Test("Eine HTML-Antwort wird nicht als Bild uebernommen")
    func ignoresHTMLResponse() async {
        let source = #"#image("https://x/f.png")"#
        let result = await TypstImageResolver.resolve(
            source: source,
            configuration: configuration(
                ["https://x/f.png": StubResponse(contentType: "text/html", data: htmlPage)]
            )
        )

        #expect(result.resolvedSource == source)
        #expect(result.imageFiles.isEmpty)
    }

    @Test("Ein Fehlerstatus laesst den Quelltext unveraendert")
    func ignoresErrorStatus() async {
        let source = #"#image("https://x/f.png")"#
        let result = await TypstImageResolver.resolve(
            source: source,
            configuration: configuration(
                ["https://x/f.png": StubResponse(statusCode: 404, contentType: "image/png", data: onePixelPNG)]
            )
        )

        #expect(result.resolvedSource == source)
        #expect(result.imageFiles.isEmpty)
    }

    // MARK: Der Normalfall

    @Test("Ein echtes Web-Bild wird geladen und nur im Literal ersetzt")
    func rewritesRealWebImage() async {
        let source = #"#image("https://x/f.png") — Quelle: https://x/f.png"#
        let result = await TypstImageResolver.resolve(
            source: source,
            configuration: configuration(
                ["https://x/f.png": StubResponse(contentType: "image/png", data: onePixelPNG)]
            )
        )

        #expect(result.resolvedSource == #"#image("__web__/f.png") — Quelle: https://x/f.png"#)
        #expect(result.imageFiles.count == 1)
        #expect(result.imageFiles.first?.path == "__web__/f.png")
        #expect(result.imageFiles.first?.content == onePixelPNG)
    }

    @Test("Pfad ueber eine #let-Bindung")
    func rewritesLetBoundWebImage() async {
        let source = """
        #let u = "https://x/f.png"
        #image(u)
        """
        let result = await TypstImageResolver.resolve(
            source: source,
            configuration: configuration(
                ["https://x/f.png": StubResponse(contentType: "image/png", data: onePixelPNG)]
            )
        )

        #expect(result.resolvedSource == """
        #let u = "__web__/f.png"
        #image(u)
        """)
        #expect(result.imageFiles.count == 1)
    }

    @Test("Derselbe Pfad in #let und image: ein Download, beide Literale ersetzt")
    func rewritesEveryOccurrenceButLoadsOnce() async {
        let source = """
        #let u = "https://x/f.png"
        #image("https://x/f.png")
        """
        let log = RequestLog()
        let result = await TypstImageResolver.resolve(
            source: source,
            configuration: configuration(
                ["https://x/f.png": StubResponse(contentType: "image/png", data: onePixelPNG)],
                log: log
            )
        )

        #expect(result.resolvedSource == """
        #let u = "__web__/f.png"
        #image("__web__/f.png")
        """)
        #expect(await log.count == 1)
        #expect(result.imageFiles.count == 1)
    }

    // MARK: Regressionen

    @Test("Dokument ohne Bilder bleibt unveraendert")
    func documentWithoutImagesIsUntouched() async {
        let source = "= Titel\nNur Text, ein Link: https://example.de/seite"
        let result = await TypstImageResolver.resolve(source: source, configuration: configuration([:]))
        #expect(result.resolvedSource == source)
        #expect(result.imageFiles.isEmpty)
    }

    @Test("Lokale img/-Referenz bleibt im Quelltext stehen")
    func localReferenceKeepsItsPath() async {
        let source = #"#image("img/a.png")"#
        let result = await TypstImageResolver.resolve(source: source, configuration: configuration([:]))
        // Ohne iCloud und ohne Cache wird nichts geladen — aber auch nichts umgeschrieben.
        #expect(result.resolvedSource == source)
    }

    @Test("Funktionen mit image-Endung loesen keinen Abruf aus")
    func ignoresSuffixedFunctionNames() async {
        let source = #"#qrimage("https://x/f.png")"#
        let log = RequestLog()
        let result = await TypstImageResolver.resolve(
            source: source,
            configuration: configuration(
                ["https://x/f.png": StubResponse(contentType: "image/png", data: onePixelPNG)],
                log: log
            )
        )

        #expect(result.resolvedSource == source)
        #expect(result.imageFiles.isEmpty)
        #expect(await log.count == 0)
    }
}
