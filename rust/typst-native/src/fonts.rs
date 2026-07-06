//! Hilfsfunktionen zum Laden von Schriftarten aus Byte-Daten.
//!
//! Die eigentliche Font-Ladung aus dem App-Bundle erfolgt auf der Swift-Seite.
//! Hier werden die rohen Bytes in Typst-Font-Objekte konvertiert.

use typst::foundations::Bytes;
use typst::text::{Font, FontInfo};

/// Laedt alle Font-Faces aus einer Font-Datei (TTF/OTF/TTC).
///
/// Eine einzelne Font-Datei kann mehrere Faces enthalten (z.B. bei .ttc-Dateien).
/// Gibt sowohl die FontInfo-Metadaten als auch die geladenen Font-Objekte zurueck.
pub fn load_fonts_from_bytes(data: &[u8]) -> (Vec<FontInfo>, Vec<Font>) {
    let bytes = Bytes::new(data.to_vec());
    let mut infos = Vec::new();
    let mut fonts = Vec::new();

    for index in 0u32.. {
        match FontInfo::new(&bytes, index) {
            Some(info) => {
                infos.push(info);
                if let Some(font) = Font::new(bytes.clone(), index) {
                    fonts.push(font);
                }
            }
            None => break,
        }
    }

    (infos, fonts)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_empty_data_returns_empty() {
        let (infos, fonts) = load_fonts_from_bytes(&[]);
        assert!(infos.is_empty());
        assert!(fonts.is_empty());
    }

    #[test]
    fn test_invalid_data_returns_empty() {
        let garbage = vec![0u8, 1, 2, 3, 4, 5];
        let (infos, fonts) = load_fonts_from_bytes(&garbage);
        assert!(infos.is_empty());
        assert!(fonts.is_empty());
    }
}
