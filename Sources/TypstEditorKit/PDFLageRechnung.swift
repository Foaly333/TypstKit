//
//  PDFLageRechnung.swift
//  TypstEditorKit
//
//  Reine Rechnungen zur Lage des sichtbaren Ausschnitts einer PDF-Vorschau
//  (Mittelpunkt <-> Scroll-Offset). Ohne UIKit/AppKit, dadurch testbar.
//

import CoreGraphics

/// Rechnungen, mit denen die PDF-Vorschau ihren sichtbaren Ausschnitt nach
/// einer Groessenaenderung oder einem Dokumentwechsel wiederherstellt.
nonisolated enum PDFLageRechnung {

    /// Inhaltsabstand einer Scroll-Ansicht (wie `UIEdgeInsets`, ohne UIKit).
    struct Einzug: Equatable, Sendable {
        var oben: CGFloat
        var links: CGFloat
        var unten: CGFloat
        var rechts: CGFloat

        static let null = Einzug(oben: 0, links: 0, unten: 0, rechts: 0)
    }

    /// Mittelpunkt eines Bereichs der Groesse `groesse` mit Ursprung (0, 0).
    static func mittelpunkt(von groesse: CGSize) -> CGPoint {
        CGPoint(x: groesse.width / 2, y: groesse.height / 2)
    }

    /// Neuer Scroll-Offset, der den Ankerpunkt (wo der gemerkte Seitenpunkt nach
    /// dem Layout in Ansichtskoordinaten liegt) auf das Ziel (die neue Mitte) schiebt.
    ///
    /// Je Achse begrenzt auf den zulaessigen Bereich `-einzug ... inhalt + einzug - sichtbar`.
    /// Passt der Inhalt auf einer Achse ganz hinein, bleibt der Offset dort unveraendert —
    /// PDFKit zentriert dann selbst.
    static func korrigierterOffset(
        aktuell: CGPoint,
        anker: CGPoint,
        ziel: CGPoint,
        inhaltsGroesse: CGSize,
        sichtbareGroesse: CGSize,
        einzug: Einzug
    ) -> CGPoint {
        CGPoint(
            x: achse(
                gewuenscht: aktuell.x + anker.x - ziel.x,
                aktuell: aktuell.x,
                inhalt: inhaltsGroesse.width,
                sichtbar: sichtbareGroesse.width,
                vorn: einzug.links,
                hinten: einzug.rechts
            ),
            y: achse(
                gewuenscht: aktuell.y + anker.y - ziel.y,
                aktuell: aktuell.y,
                inhalt: inhaltsGroesse.height,
                sichtbar: sichtbareGroesse.height,
                vorn: einzug.oben,
                hinten: einzug.unten
            )
        )
    }

    /// Begrenzt einen gewuenschten Offset auf einer Achse.
    static func achse(
        gewuenscht: CGFloat,
        aktuell: CGFloat,
        inhalt: CGFloat,
        sichtbar: CGFloat,
        vorn: CGFloat,
        hinten: CGFloat
    ) -> CGFloat {
        let minimum = -vorn
        let maximum = inhalt + hinten - sichtbar
        guard maximum > minimum else { return aktuell }
        return min(max(gewuenscht, minimum), maximum)
    }

    /// Ob zwei Seitengroessen dasselbe Format sind (Toleranz fuer Rundung).
    static func gleichesFormat(_ a: CGSize, _ b: CGSize, toleranz: CGFloat = 0.5) -> Bool {
        abs(a.width - b.width) <= toleranz && abs(a.height - b.height) <= toleranz
    }

    /// Seitenindex fuer ein Dokument mit `seitenzahl` Seiten; bei weniger Seiten
    /// die letzte, ohne Seiten nil.
    static func begrenzterSeitenIndex(_ index: Int, seitenzahl: Int) -> Int? {
        guard seitenzahl > 0 else { return nil }
        return min(max(index, 0), seitenzahl - 1)
    }

    /// Merkt den Ausschnitt, den der Nutzer zuletzt selbst eingestellt hat, ueber
    /// mehrere Groessenaenderungen hinweg.
    ///
    /// Jede Groessenaenderung rechnet vom gemerkten Anker aus, nicht vom gerade
    /// sichtbaren Mittelpunkt. Sonst geht eine Achse verloren, auf der die Seite
    /// zwischenzeitlich ganz hineinpasst (PDFKit zentriert sie dann): schmal ->
    /// breit -> schmal stuende danach die Seitenmitte statt des alten Ausschnitts
    /// in der Mitte. Scrollt oder zoomt der Nutzer, wird der Anker vergessen.
    struct AnkerGedaechtnis<Anker> {
        private(set) var gemerkt: Anker?

        init() {}

        /// Anker fuer eine Groessenaenderung: der gemerkte, sonst der sichtbare
        /// (der dann gemerkt wird).
        mutating func ankerFuerGroessenwechsel(sichtbar: () -> Anker?) -> Anker? {
            if let gemerkt { return gemerkt }
            gemerkt = sichtbar()
            return gemerkt
        }

        /// Der Nutzer hat den Ausschnitt selbst veraendert (oder die Lage ist
        /// nicht mehr vergleichbar): naechste Groessenaenderung rechnet neu.
        mutating func vergiss() {
            gemerkt = nil
        }
    }

    /// Ob eine Ansichtsgroesse fuer Lageberechnungen taugt (beide Seiten > 0).
    static func istBrauchbar(_ groesse: CGSize) -> Bool {
        groesse.width > 0 && groesse.height > 0
    }
}
