import CoreGraphics
import Testing
@testable import TypstEditorKit

struct PDFLageRechnungTests {

    @Test("Mittelpunkt liegt in der Mitte der Groesse")
    func mittelpunkt() {
        #expect(PDFLageRechnung.mittelpunkt(von: CGSize(width: 200, height: 100)) == CGPoint(x: 100, y: 50))
    }

    @Test("Schmaler gewordene Ansicht: Anker wandert zurueck in die neue Mitte")
    func ankerInNeueMitte() {
        // Seite 400 breit, Ansicht von 245 auf 160 schmaler. PDFKit hat den
        // Offset auf 0 gesetzt, der Anker liegt nach dem Layout bei x = 200.
        let neu = PDFLageRechnung.korrigierterOffset(
            aktuell: CGPoint(x: 0, y: 300),
            anker: CGPoint(x: 200, y: 150),
            ziel: CGPoint(x: 80, y: 150),
            inhaltsGroesse: CGSize(width: 400, height: 2000),
            sichtbareGroesse: CGSize(width: 160, height: 300),
            einzug: .null
        )
        #expect(neu == CGPoint(x: 120, y: 300))
    }

    @Test("Offset wird auf den zulaessigen Bereich begrenzt")
    func begrenzung() {
        let neu = PDFLageRechnung.korrigierterOffset(
            aktuell: CGPoint(x: 0, y: 0),
            anker: CGPoint(x: 1000, y: -500),
            ziel: CGPoint(x: 50, y: 50),
            inhaltsGroesse: CGSize(width: 400, height: 2000),
            sichtbareGroesse: CGSize(width: 100, height: 100),
            einzug: PDFLageRechnung.Einzug(oben: 10, links: 0, unten: 20, rechts: 5)
        )
        #expect(neu == CGPoint(x: 305, y: -10))
    }

    @Test("Passt der Inhalt auf einer Achse ganz hinein, bleibt der Offset dort")
    func inhaltPasstHinein() {
        let neu = PDFLageRechnung.korrigierterOffset(
            aktuell: CGPoint(x: -12, y: 40),
            anker: CGPoint(x: 90, y: 100),
            ziel: CGPoint(x: 150, y: 50),
            inhaltsGroesse: CGSize(width: 250, height: 2000),
            sichtbareGroesse: CGSize(width: 300, height: 100),
            einzug: .null
        )
        #expect(neu == CGPoint(x: -12, y: 90))
    }

    @Test("Gleiches Seitenformat mit Rundungstoleranz", arguments: [
        (CGSize(width: 595.28, height: 841.89), CGSize(width: 595, height: 842), true),
        (CGSize(width: 595, height: 842), CGSize(width: 842, height: 595), false),
        (CGSize(width: 595, height: 842), CGSize(width: 612, height: 792), false),
    ])
    func gleichesFormat(a: CGSize, b: CGSize, erwartet: Bool) {
        #expect(PDFLageRechnung.gleichesFormat(a, b) == erwartet)
    }

    @Test("Seitenindex wird auf die vorhandenen Seiten begrenzt", arguments: [
        (3, 5, Optional(3)),
        (7, 5, Optional(4)),
        (-1, 5, Optional(0)),
        (0, 0, nil),
    ])
    func seitenIndex(index: Int, seitenzahl: Int, erwartet: Int?) {
        #expect(PDFLageRechnung.begrenzterSeitenIndex(index, seitenzahl: seitenzahl) == erwartet)
    }

    @Test("Nur Groessen mit Breite und Hoehe sind brauchbar")
    func brauchbar() {
        #expect(PDFLageRechnung.istBrauchbar(CGSize(width: 1, height: 1)))
        #expect(!PDFLageRechnung.istBrauchbar(CGSize(width: 0, height: 100)))
        #expect(!PDFLageRechnung.istBrauchbar(.zero))
    }

    // MARK: Anker ueber mehrere Groessenaenderungen

    @Test("Gemerkter Anker bleibt ueber Groessenaenderungen, bis er vergessen wird")
    func ankerGedaechtnis() {
        var gedaechtnis = PDFLageRechnung.AnkerGedaechtnis<CGFloat>()
        #expect(gedaechtnis.ankerFuerGroessenwechsel { 150 } == 150)
        #expect(gedaechtnis.ankerFuerGroessenwechsel { 300 } == 150)
        gedaechtnis.vergiss()
        #expect(gedaechtnis.ankerFuerGroessenwechsel { 300 } == 300)
    }

    /// Waagerechte Achse, Seite (gezoomt) 600 breit, linker Seitenrand sichtbar.
    /// Schmal (300) -> breit (800, Seite passt, PDFKit zentriert: Offset -100)
    /// -> wieder schmal. Anker als Inhaltskoordinate des sichtbaren Mittelpunkts.
    private func offsetNachRueckkehr(mitGedaechtnis: Bool) -> CGFloat {
        let seite: CGFloat = 600
        var gedaechtnis = PDFLageRechnung.AnkerGedaechtnis<CGFloat>()
        var offset: CGFloat = 0

        // schmal -> breit: Anker = Mitte der schmalen Ansicht
        var anker = gedaechtnis.ankerFuerGroessenwechsel { offset + 300 / 2 }!
        offset = PDFLageRechnung.achse(
            gewuenscht: offset + (anker - offset) - 800 / 2,
            aktuell: -100, inhalt: seite, sichtbar: 800, vorn: 0, hinten: 0
        )
        #expect(offset == -100)
        if !mitGedaechtnis { gedaechtnis.vergiss() }

        // breit -> schmal: PDFKit setzt den Offset nach dem Layout auf 0
        anker = gedaechtnis.ankerFuerGroessenwechsel { offset + 800 / 2 }!
        let nachLayout: CGFloat = 0
        return PDFLageRechnung.korrigierterOffset(
            aktuell: CGPoint(x: nachLayout, y: 0),
            anker: CGPoint(x: anker - nachLayout, y: 50),
            ziel: CGPoint(x: 300 / 2, y: 50),
            inhaltsGroesse: CGSize(width: seite, height: 2000),
            sichtbareGroesse: CGSize(width: 300, height: 100),
            einzug: .null
        ).x
    }

    @Test("Schmal -> breit -> schmal zeigt mit gemerktem Anker wieder denselben Ausschnitt")
    func rueckkehrGleicherAusschnitt() {
        #expect(offsetNachRueckkehr(mitGedaechtnis: true) == 0)
        // Gegenprobe: vom zentrierten Zwischenzustand aus gerechnet springt der
        // Ausschnitt um die halbe Breite nach rechts (Befund 51 der App).
        #expect(offsetNachRueckkehr(mitGedaechtnis: false) == 150)
    }
}
