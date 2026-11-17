//
//  TypstPDFView.swift
//  TypstEditorKit
//
//  PDFView-Unterklasse der Vorschau (iOS). Ergaenzt PDFKit um drei Dinge:
//  - Lage halten: Aendert sich die Groesse bei gezoomter Vorschau, bleibt der
//    sichtbare Mittelpunkt (Seite + Punkt) an derselben Stelle. Bezug ist der
//    Ausschnitt vor der ersten Groessenaenderung seit der letzten Nutzergeste.
//  - Fokus nicht stehlen: Neues Dokument oder Eintritt ins Fenster machen die
//    PDF-Dokumentansicht nicht zum First Responder (Tastatur des Editors bleibt).
//  - Dokumentwechsel ohne Sprung: Gleiches Seitenformat -> Zoom, Seite und Lage
//    bleiben; erstes Dokument bzw. erste Seiten -> passend skalieren.
//

#if canImport(UIKit)
import UIKit
import PDFKit

/// Vorschau-PDFView von TypstKit (iOS). Dokumente werden ueber
/// `uebernimm(_:)` gesetzt, nicht ueber `document =`.
final class TypstPDFView: PDFView {

    /// Ein sichtbarer Punkt in Seitenkoordinaten.
    private struct SeitenAnker {
        let seitenIndex: Int
        let punkt: CGPoint
    }

    /// Groesse beim letzten Layout mit brauchbarer Groesse.
    private var letzteGroesse: CGSize = .zero
    /// Sperre gegen Wiedereintritt, waehrend der Offset korrigiert wird.
    private var passtLageAn = false
    /// Ausschnitt, den der Nutzer zuletzt eingestellt hat — Bezug fuer alle
    /// folgenden Groessenaenderungen, bis er selbst scrollt oder zoomt.
    private var lageAnker = PDFLageRechnung.AnkerGedaechtnis<SeitenAnker>()
    /// Laeuft gerade eine Massstabsaenderung, die nicht vom Nutzer kommt.
    private var aendertMassstabSelbst = false
    /// Scroll-Ansicht, an deren Gesten die Vorschau haengt.
    private weak var beobachteteScrollAnsicht: UIScrollView?

    /// First Responder ausserhalb der Vorschau, der vor einer Zuweisung aktiv war.
    private weak var geschuetzterFokus: UIResponder?
    private var istFokusSchutzAktiv = false
    private var fokusSchutzEnde: Task<Void, Never>?

    /// Seitenzahl, die die Vorschau zuletzt kannte (erkennt "erstmals Seiten").
    private var bekannteSeitenzahl = 0
    private var istNeuskalierungGeplant = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        beobachteSichtbareSeiten()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        beobachteSichtbareSeiten()
    }

    private func beobachteSichtbareSeiten() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sichtbareSeitenGeaendert(_:)),
            name: .PDFViewVisiblePagesChanged,
            object: self
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(massstabGeaendert(_:)),
            name: .PDFViewScaleChanged,
            object: self
        )
    }

    // MARK: Nutzer veraendert den Ausschnitt

    /// Haengt die Vorschau an Ziehen und Zoomen der inneren Scroll-Ansicht.
    private func verbindeGesten() {
        guard let scrollAnsicht = innereScrollAnsicht(), scrollAnsicht !== beobachteteScrollAnsicht else { return }
        beobachteteScrollAnsicht = scrollAnsicht
        scrollAnsicht.panGestureRecognizer.addTarget(self, action: #selector(nutzerGeste(_:)))
        scrollAnsicht.pinchGestureRecognizer?.addTarget(self, action: #selector(nutzerGeste(_:)))
    }

    @objc private func nutzerGeste(_ geste: UIGestureRecognizer) {
        if geste.state == .began || geste.state == .changed {
            lageAnker.vergiss()
        }
    }

    /// Zoom durch den Nutzer (auch Doppeltippen) vergisst den Anker.
    @objc private func massstabGeaendert(_ notification: Notification) {
        guard !aendertMassstabSelbst, !passtLageAn else { return }
        lageAnker.vergiss()
    }

    private func mitEigenemMassstab(_ arbeit: () -> Void) {
        let vorher = aendertMassstabSelbst
        aendertMassstabSelbst = true
        arbeit()
        aendertMassstabSelbst = vorher
    }

    // MARK: Dokument setzen

    /// Setzt ein neues Dokument, ohne Fokus, Zoom und Lage zu verlieren.
    func uebernimm(_ neues: PDFDocument) {
        guard document !== neues else { return }
        let altes = document
        let hatteSeiten = (altes?.pageCount ?? 0) > 0
        var istGleichesFormat = false
        if hatteSeiten,
           let altesFormat = Self.format(von: altes?.page(at: 0)),
           let neuesFormat = Self.format(von: neues.page(at: 0)) {
            istGleichesFormat = PDFLageRechnung.gleichesFormat(altesFormat, neuesFormat)
        }
        let warAutomatisch = autoScales
        let massstab = scaleFactor
        // Ein gemerkter Anker (Ausschnitt vor einer Groessenaenderung) hat Vorrang
        // vor dem gerade sichtbaren Mittelpunkt.
        let anker = istGleichesFormat && PDFLageRechnung.istBrauchbar(bounds.size)
            ? (lageAnker.gemerkt ?? sichtbarerAnker(beiGroesse: bounds.size))
            : nil
        if !istGleichesFormat { lageAnker.vergiss() }

        mitFokusSchutz {
            mitEigenemMassstab {
                document = neues
                bekannteSeitenzahl = neues.pageCount
                if istGleichesFormat {
                    if !warAutomatisch { scaleFactor = massstab }
                    layoutIfNeeded()
                    if let anker { stelle(anker) }
                } else if !hatteSeiten, neues.pageCount > 0 {
                    skalierePassend()
                }
            }
        }

        // Falls PDFKit nach der Zuweisung noch selbst an die erste Seite springt:
        // einmal im naechsten Durchlauf nachziehen (ohne Wirkung, wenn die Lage stimmt).
        if let anker {
            Task { [weak self] in
                guard let self, self.document === neues else { return }
                self.stelle(anker)
            }
        }
    }

    private static func format(von seite: PDFPage?) -> CGSize? {
        seite?.bounds(for: .mediaBox).size
    }

    // MARK: Layout

    override func layoutSubviews() {
        let neueGroesse = bounds.size
        if autoScales { lageAnker.vergiss() }
        // Anker VOR dem Layout von PDFKit bestimmen: Offset und Dokumentansicht
        // sind dann noch im alten Zustand, die alte Mitte ist die der alten Groesse.
        // Gerechnet wird vom gemerkten Anker aus (erste Groessenaenderung seit der
        // letzten Nutzergeste merkt ihn), damit schmal -> breit -> schmal wieder
        // denselben Ausschnitt zeigt, auch wenn die Seite dazwischen ganz hineinpasste.
        let anker: SeitenAnker? =
            !passtLageAn
            && !autoScales
            && PDFLageRechnung.istBrauchbar(letzteGroesse)
            && PDFLageRechnung.istBrauchbar(neueGroesse)
            && neueGroesse != letzteGroesse
            ? lageAnker.ankerFuerGroessenwechsel { sichtbarerAnker(beiGroesse: letzteGroesse) }
            : nil
        let massstab = scaleFactor

        mitEigenemMassstab { super.layoutSubviews() }
        verbindeGesten()

        if PDFLageRechnung.istBrauchbar(neueGroesse) {
            letzteGroesse = neueGroesse
        }
        if let anker, !autoScales, abs(scaleFactor - massstab) < 0.0001 {
            stelle(anker)
        }
        pruefeSeitenzuwachs()
        gibFokusZurueckFallsGestohlen()
    }

    /// Sichtbarer Mittelpunkt bei der Ansichtsgroesse `groesse`, in Seitenkoordinaten.
    private func sichtbarerAnker(beiGroesse groesse: CGSize) -> SeitenAnker? {
        guard let document else { return nil }
        let mitte = PDFLageRechnung.mittelpunkt(von: groesse)
        guard let seite = page(for: mitte, nearest: true) else { return nil }
        let index = document.index(for: seite)
        guard index != NSNotFound else { return nil }
        return SeitenAnker(seitenIndex: index, punkt: convert(mitte, to: seite))
    }

    /// Schiebt den Ausschnitt so, dass der Anker in der Mitte der Ansicht liegt.
    private func stelle(_ anker: SeitenAnker) {
        guard
            !passtLageAn,
            let document,
            let index = PDFLageRechnung.begrenzterSeitenIndex(anker.seitenIndex, seitenzahl: document.pageCount),
            let seite = document.page(at: index),
            let scrollAnsicht = innereScrollAnsicht(),
            PDFLageRechnung.istBrauchbar(bounds.size)
        else { return }

        let einzug = scrollAnsicht.adjustedContentInset
        let neu = PDFLageRechnung.korrigierterOffset(
            aktuell: scrollAnsicht.contentOffset,
            anker: convert(anker.punkt, from: seite),
            ziel: PDFLageRechnung.mittelpunkt(von: bounds.size),
            inhaltsGroesse: scrollAnsicht.contentSize,
            sichtbareGroesse: scrollAnsicht.bounds.size,
            einzug: PDFLageRechnung.Einzug(
                oben: einzug.top, links: einzug.left, unten: einzug.bottom, rechts: einzug.right
            )
        )
        guard abs(neu.x - scrollAnsicht.contentOffset.x) > 0.5
            || abs(neu.y - scrollAnsicht.contentOffset.y) > 0.5
        else { return }

        passtLageAn = true
        scrollAnsicht.setContentOffset(neu, animated: false)
        passtLageAn = false
    }

    /// Die Scroll-Ansicht, in der PDFKit die Seiten zeigt (flache Suche).
    private func innereScrollAnsicht() -> UIScrollView? {
        var ebene: [UIView] = subviews
        for _ in 0..<3 {
            if let treffer = ebene.first(where: { $0 is UIScrollView }) as? UIScrollView {
                return treffer
            }
            ebene = ebene.flatMap(\.subviews)
        }
        return nil
    }

    // MARK: Erste Seiten -> passend skalieren

    @objc private func sichtbareSeitenGeaendert(_ notification: Notification) {
        pruefeSeitenzuwachs()
    }

    /// Bekommt das (gleiche) Dokument erstmals Seiten, rechnet PDFKit den Massstab
    /// nicht neu. Dann im naechsten Durchlauf passend skalieren.
    private func pruefeSeitenzuwachs() {
        let anzahl = document?.pageCount ?? 0
        let warLeer = bekannteSeitenzahl == 0
        bekannteSeitenzahl = anzahl
        guard warLeer, anzahl > 0, !istNeuskalierungGeplant else { return }
        istNeuskalierungGeplant = true
        Task { [weak self] in
            guard let self else { return }
            self.istNeuskalierungGeplant = false
            guard (self.document?.pageCount ?? 0) > 0 else { return }
            self.mitFokusSchutz { self.mitEigenemMassstab { self.skalierePassend() } }
        }
    }

    private func skalierePassend() {
        layoutDocumentView()
        let passend = scaleFactorForSizeToFit
        autoScales = false
        if passend > 0 { scaleFactor = passend }
        autoScales = true
    }

    // MARK: Fokus

    override func didMoveToWindow() {
        guard window != nil else {
            super.didMoveToWindow()
            return
        }
        mitFokusSchutz { super.didMoveToWindow() }
    }

    /// Ausdrueckliches Antippen der Vorschau beendet den Schutz: Textauswahl
    /// im PDF soll den Fokus bekommen duerfen.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let treffer = super.hitTest(point, with: event)
        if treffer != nil, event?.type == .touches {
            beendeFokusSchutz()
        }
        return treffer
    }

    /// Fuehrt `arbeit` aus und gibt den First Responder zurueck, falls er dabei
    /// (oder kurz danach) auf die Vorschau gewechselt ist.
    private func mitFokusSchutz(_ arbeit: () -> Void) {
        if !istFokusSchutzAktiv {
            geschuetzterFokus = fokusAusserhalb()
        }
        istFokusSchutzAktiv = geschuetzterFokus != nil
        arbeit()
        gibFokusZurueckFallsGestohlen()
        guard istFokusSchutzAktiv else { return }

        // PDFKit kann den Fokus auch erst im folgenden Layout-Durchlauf nehmen:
        // Schutz noch einen Durchlauf und eine kurze Frist aufrechterhalten.
        fokusSchutzEnde?.cancel()
        fokusSchutzEnde = Task { [weak self] in
            self?.gibFokusZurueckFallsGestohlen()
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.gibFokusZurueckFallsGestohlen()
            self?.beendeFokusSchutz()
        }
    }

    private func beendeFokusSchutz() {
        istFokusSchutzAktiv = false
        geschuetzterFokus = nil
        fokusSchutzEnde?.cancel()
        fokusSchutzEnde = nil
    }

    private func gibFokusZurueckFallsGestohlen() {
        guard
            istFokusSchutzAktiv,
            let vorher = geschuetzterFokus,
            !vorher.isFirstResponder,
            let jetzt = window?.typstFirstResponder(),
            jetzt === self || jetzt.isDescendant(of: self)
        else { return }
        if let ansicht = vorher as? UIView, ansicht.window == nil { return }
        _ = vorher.becomeFirstResponder()
    }

    /// Aktueller First Responder im Fenster, sofern er nicht zur Vorschau gehoert.
    private func fokusAusserhalb() -> UIResponder? {
        guard let aktuell = window?.typstFirstResponder() else { return nil }
        if aktuell === self || aktuell.isDescendant(of: self) { return nil }
        return aktuell
    }
}

private extension UIView {
    /// Sucht den First Responder in dieser Ansicht und ihren Unteransichten.
    func typstFirstResponder() -> UIView? {
        if isFirstResponder { return self }
        for unteransicht in subviews {
            if let treffer = unteransicht.typstFirstResponder() { return treffer }
        }
        return nil
    }
}

#endif
