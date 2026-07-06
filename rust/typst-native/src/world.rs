//! Implementierung des `typst::World`-Traits fuer die iOS-Integration.
//!
//! Fonts werden als Byte-Arrays von Swift uebergeben.
//! Packages werden als PackageFile-Listen von Swift uebergeben und
//! ueber FileId aufgeloest (namespace/name/version + Pfad).

use std::collections::HashMap;
use typst::diag::{FileError, FileResult};
use typst::foundations::Bytes;
use typst::syntax::package::{PackageSpec, PackageVersion};
use typst::syntax::{FileId, Source, VirtualPath};
use typst::text::{Font, FontBook};
use typst::utils::LazyHash;
use typst::Library;

use crate::fonts;

/// Virtuelle Bilddatei fuer Typst (aus dem Web oder lokal), uebergeben von Swift via FFI.
/// Der Pfad muss genau dem im Typst-Quelltext verwendeten Pfad entsprechen
/// (z.B. "img/foto.png" oder "__web__/foto.png").
#[derive(Debug, Clone, uniffi::Record)]
pub struct ImageFile {
    /// Virtueller Pfad, unter dem das Bild in Typst angesprochen wird
    pub path: String,
    /// Rohe Bilddaten (z.B. PNG- oder JPEG-Bytes)
    pub content: Vec<u8>,
}

/// Eine einzelne Datei aus einem Typst-Package, uebergeben von Swift via FFI.
#[derive(Debug, Clone, uniffi::Record)]
pub struct PackageFile {
    /// Package-Namespace (z.B. "preview")
    pub namespace: String,
    /// Package-Name (z.B. "cades")
    pub name: String,
    /// Package-Version (z.B. "0.3.1")
    pub version: String,
    /// Relativer Pfad innerhalb des Packages (z.B. "lib.typ")
    pub path: String,
    /// Dateiinhalt als Bytes
    pub content: Vec<u8>,
}

/// Repraesentiert die "Welt" fuer den Typst-Compiler.
/// Enthaelt Quelltext, Schriften, Standardbibliothek und Package-Dateien.
pub struct TypstWorld {
    library: LazyHash<Library>,
    book: LazyHash<FontBook>,
    source: Source,
    fonts: Vec<Font>,
    /// Package-Quelldateien (*.typ), indexiert nach FileId
    package_sources: HashMap<FileId, Source>,
    /// Package-Binaerdateien (Bilder etc.), indexiert nach FileId
    package_files: HashMap<FileId, Bytes>,
    /// Virtuelle Bilddateien (Web-Downloads + lokale img/-Dateien), indexiert nach Pfad
    virtual_files: HashMap<String, Bytes>,
}

impl TypstWorld {
    /// Erstellt eine neue World-Instanz.
    ///
    /// - `source_text`: Der zu kompilierende Typst-Quelltext
    /// - `font_data`: Font-Dateien als rohe Bytes (TTF/OTF/TTC)
    /// - `packages`: Package-Dateien von Swift, bereits entpackt
    pub fn new(source_text: String, font_data: Vec<Vec<u8>>, packages: Vec<PackageFile>, images: Vec<ImageFile>) -> Self {
        let mut book = FontBook::new();
        let mut all_fonts = Vec::new();

        // Eingebettete Standard-Schriften zuerst registrieren (Libertinus Serif,
        // New Computer Modern, New Computer Modern Math, DejaVu Sans Mono).
        // Dadurch haben Standard-Text UND der Math-Modus immer eine gueltige
        // Schrift — unabhaengig davon, was die Swift-Seite liefert.
        #[cfg(feature = "embed-fonts")]
        for data in typst_assets::fonts() {
            let (infos, loaded_fonts) = fonts::load_fonts_from_bytes(data);
            for info in infos {
                book.push(info);
            }
            all_fonts.extend(loaded_fonts);
        }

        // Schriften aus den uebergebenen Byte-Arrays laden
        for data in &font_data {
            let (infos, loaded_fonts) = fonts::load_fonts_from_bytes(data);
            for info in infos {
                book.push(info);
            }
            all_fonts.extend(loaded_fonts);
        }

        // Hauptquelle mit definiertem Pfad statt Source::detached,
        // damit relative Imports korrekt aufgeloest werden
        let main_id = FileId::new(None, VirtualPath::new("/main.typ"));
        let source = Source::new(main_id, source_text);

        // Package-Dateien in HashMaps einsortieren
        let mut package_sources = HashMap::new();
        let mut package_files = HashMap::new();

        for pf in packages {
            // Lokale Import-Dateien (namespace "__local__"):
            // Ohne PackageSpec registrieren, damit #import "file.typ" funktioniert
            if pf.namespace == "__local__" {
                let vpath = VirtualPath::new(&pf.path);
                let file_id = FileId::new(None, vpath);

                if pf.path.ends_with(".typ") {
                    let content = String::from_utf8_lossy(&pf.content).into_owned();
                    let src = Source::new(file_id, content);
                    package_sources.insert(file_id, src);
                } else {
                    package_files.insert(file_id, Bytes::new(pf.content));
                }
                continue;
            }

            let Ok(version) = pf.version.parse::<PackageVersion>() else {
                continue;
            };
            let spec = PackageSpec {
                namespace: pf.namespace.into(),
                name: pf.name.into(),
                version,
            };
            let vpath = VirtualPath::new(&pf.path);
            let file_id = FileId::new(Some(spec), vpath);

            if pf.path.ends_with(".typ") {
                // Typst-Quelldateien als Source parsen
                let content = String::from_utf8_lossy(&pf.content).into_owned();
                let src = Source::new(file_id, content);
                package_sources.insert(file_id, src);
            } else {
                // Alle anderen Dateien als rohe Bytes speichern
                package_files.insert(file_id, Bytes::new(pf.content));
            }
        }

        // Virtuelle Bilddateien einsortieren (Pfad → Bytes)
        let virtual_files: HashMap<String, Bytes> = images
            .into_iter()
            .map(|img| (img.path, Bytes::new(img.content)))
            .collect();

        Self {
            library: LazyHash::new(Library::default()),
            book: LazyHash::new(book),
            source,
            fonts: all_fonts,
            package_sources,
            package_files,
            virtual_files,
        }
    }
}

impl typst::World for TypstWorld {
    fn library(&self) -> &LazyHash<Library> {
        &self.library
    }

    fn book(&self) -> &LazyHash<FontBook> {
        &self.book
    }

    fn main(&self) -> FileId {
        self.source.id()
    }

    fn source(&self, id: FileId) -> FileResult<Source> {
        if id == self.source.id() {
            Ok(self.source.clone())
        } else if let Some(src) = self.package_sources.get(&id) {
            Ok(src.clone())
        } else {
            Err(FileError::NotFound(id.vpath().as_rootless_path().into()))
        }
    }

    fn file(&self, id: FileId) -> FileResult<Bytes> {
        // Virtuelle Bilddateien (keine Package-Zuordnung) anhand des Pfads aufloesen
        if id.package().is_none() {
            let rootless = id.vpath().as_rootless_path().to_string_lossy().into_owned();
            if let Some(bytes) = self.virtual_files.get(&rootless) {
                return Ok(bytes.clone());
            }
        }
        if let Some(bytes) = self.package_files.get(&id) {
            Ok(bytes.clone())
        } else if let Some(src) = self.package_sources.get(&id) {
            // Typst-Quelldateien koennen auch als rohe Bytes angefragt werden
            Ok(Bytes::new(src.text().as_bytes().to_vec()))
        } else {
            Err(FileError::NotFound(id.vpath().as_rootless_path().into()))
        }
    }

    fn font(&self, index: usize) -> Option<Font> {
        self.fonts.get(index).cloned()
    }

    fn today(&self, offset: Option<i64>) -> Option<typst::foundations::Datetime> {
        let now = time::OffsetDateTime::now_utc();
        let adjusted = match offset {
            None => now,
            Some(hours) => {
                let utc_offset = time::UtcOffset::from_hms(hours as i8, 0, 0).ok()?;
                now.to_offset(utc_offset)
            }
        };

        typst::foundations::Datetime::from_ymd_hms(
            adjusted.year(),
            adjusted.month() as u8,
            adjusted.day(),
            adjusted.hour(),
            adjusted.minute(),
            adjusted.second(),
        )
    }
}
