#!/bin/bash
set -euo pipefail

# =============================================================================
# Build-Script: Kompiliert die Rust-Crate typst-native fuer iOS UND macOS
# und erstellt ein XCFramework + Swift-Bindings via UniFFI.
#
# Erzeugt ein DYNAMISCHES Framework (cdylib), damit die Rust-Binary
# nicht in die Haupt-App gelinkt wird. Das ermoeglicht SwiftUI-Previews,
# da die Haupt-Binary klein bleibt.
#
# Ausgaben (relativ zum TypstKit-Paket):
#   Binaries/TypstNative.xcframework          — ios-arm64, ios-arm64-simulator, macos (universal)
#   Sources/TypstNativeBindings/TypstNative.swift — generierte Swift-Bindings
#   Sources/TypstNativeFFI/include/TypstNativeFFI.h — generierter C-Header
#
# Voraussetzungen:
#   rustup target add aarch64-apple-ios aarch64-apple-ios-sim aarch64-apple-darwin x86_64-apple-darwin
#
# Verwendung:
#   ./build-xcframework.sh          # Release-Build (Standard)
#   ./build-xcframework.sh debug    # Debug-Build (schneller, groesser)
# =============================================================================

# Cargo/Rustup in PATH aufnehmen falls noetig
if [ -f "$HOME/.cargo/env" ]; then
    source "$HOME/.cargo/env"
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CRATE_DIR="$SCRIPT_DIR/typst-native"
PACKAGE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR="$PACKAGE_DIR/Binaries/TypstNative.xcframework"
BINDINGS_TARGET_DIR="$PACKAGE_DIR/Sources/TypstNativeBindings"
HEADER_TARGET_DIR="$PACKAGE_DIR/Sources/TypstNativeFFI/include"
CRATE_NAME="typst_native"
FRAMEWORK_NAME="TypstNative"

# Build-Profil bestimmen
PROFILE="${1:-release}"
if [ "$PROFILE" = "debug" ]; then
    CARGO_FLAG=""
    TARGET_SUBDIR="debug"
    echo "==> Debug-Build gestartet"
else
    CARGO_FLAG="--release"
    TARGET_SUBDIR="release"
    echo "==> Release-Build gestartet"
fi

# Pruefen ob Rust-Targets installiert sind
echo "==> Pruefe Rust-Targets..."
for target in aarch64-apple-ios aarch64-apple-ios-sim aarch64-apple-darwin x86_64-apple-darwin; do
    if ! rustup target list --installed | grep -q "$target"; then
        echo "   Installiere $target..."
        rustup target add "$target"
    fi
done

# In die Crate wechseln
cd "$CRATE_DIR"

echo "==> Kompiliere fuer aarch64-apple-ios (iPhone/iPad)..."
cargo build $CARGO_FLAG --target aarch64-apple-ios

echo "==> Kompiliere fuer aarch64-apple-ios-sim (Simulator ARM64)..."
cargo build $CARGO_FLAG --target aarch64-apple-ios-sim

echo "==> Kompiliere fuer aarch64-apple-darwin (macOS Apple Silicon)..."
cargo build $CARGO_FLAG --target aarch64-apple-darwin

echo "==> Kompiliere fuer x86_64-apple-darwin (macOS Intel)..."
cargo build $CARGO_FLAG --target x86_64-apple-darwin

# Swift-Bindings mit UniFFI generieren (verwendet die staticlib fuer Analyse)
echo "==> Generiere Swift-Bindings via UniFFI..."
BINDGEN_OUT="$(mktemp -d)"
cargo run --bin uniffi-bindgen generate \
    --library "target/aarch64-apple-ios/$TARGET_SUBDIR/lib${CRATE_NAME}.a" \
    --language swift \
    --out-dir "$BINDGEN_OUT"

# Generierte Dateien ins Paket kopieren.
# WICHTIG: TypstNativeBindings ist ein eigenes SPM-Target OHNE
# MainActor-Default-Isolation — der generierte Code kann daher
# unveraendert uebernommen werden (keine nonisolated-Patches noetig).
mkdir -p "$BINDINGS_TARGET_DIR" "$HEADER_TARGET_DIR"
cp "$BINDGEN_OUT/TypstNative.swift" "$BINDINGS_TARGET_DIR/TypstNative.swift"
cp "$BINDGEN_OUT/TypstNativeFFI.h" "$HEADER_TARGET_DIR/TypstNativeFFI.h"

# Headers fuer XCFramework vorbereiten
echo "==> Bereite Headers vor..."
HEADERS_DIR="$(mktemp -d)"
cp "$BINDGEN_OUT/TypstNativeFFI.h" "$HEADERS_DIR/"

# Modulemap fuer das Framework (Modulname = Framework-Name).
# Der Swift-Import laeuft ueber das separate SPM-Target TypstNativeFFI;
# diese Modulemap dient nur der Framework-Konsistenz.
cat > "$HEADERS_DIR/module.modulemap" << 'MODULEMAP'
framework module TypstNative {
    header "TypstNativeFFI.h"
    export *
}
MODULEMAP

# Framework-Bundles erstellen
echo "==> Erstelle Framework-Bundles..."
STAGING_DIR="$(mktemp -d)"

write_info_plist() {
    local PLIST_PATH="$1"
    local PLATFORM="$2"   # ios | macos

    local MIN_OS_KEY="MinimumOSVersion"
    local MIN_OS_VALUE="16.0"
    if [ "$PLATFORM" = "macos" ]; then
        MIN_OS_KEY="LSMinimumSystemVersion"
        MIN_OS_VALUE="14.0"
    fi

    cat > "$PLIST_PATH" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>${FRAMEWORK_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>com.typst-native.${FRAMEWORK_NAME}</string>
    <key>CFBundleName</key>
    <string>${FRAMEWORK_NAME}</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundlePackageType</key>
    <string>FMWK</string>
    <key>${MIN_OS_KEY}</key>
    <string>${MIN_OS_VALUE}</string>
</dict>
PLIST
    echo "</plist>" >> "$PLIST_PATH"
}

# Flaches Framework (iOS/Simulator)
create_ios_framework() {
    local ARCH_DIR="$1"
    local DYLIB_PATH="$2"
    local FW_DIR="$STAGING_DIR/$ARCH_DIR/$FRAMEWORK_NAME.framework"

    mkdir -p "$FW_DIR/Headers" "$FW_DIR/Modules"
    cp "$DYLIB_PATH" "$FW_DIR/$FRAMEWORK_NAME"
    cp "$HEADERS_DIR"/*.h "$FW_DIR/Headers/"
    cp "$HEADERS_DIR/module.modulemap" "$FW_DIR/Modules/"
    write_info_plist "$FW_DIR/Info.plist" "ios"

    install_name_tool -id "@rpath/$FRAMEWORK_NAME.framework/$FRAMEWORK_NAME" "$FW_DIR/$FRAMEWORK_NAME" 2>/dev/null || true
}

# Versioniertes Framework (macOS verlangt Versions/A-Struktur)
create_macos_framework() {
    local ARCH_DIR="$1"
    local DYLIB_PATH="$2"
    local FW_DIR="$STAGING_DIR/$ARCH_DIR/$FRAMEWORK_NAME.framework"
    local V_DIR="$FW_DIR/Versions/A"

    mkdir -p "$V_DIR/Headers" "$V_DIR/Modules" "$V_DIR/Resources"
    cp "$DYLIB_PATH" "$V_DIR/$FRAMEWORK_NAME"
    cp "$HEADERS_DIR"/*.h "$V_DIR/Headers/"
    cp "$HEADERS_DIR/module.modulemap" "$V_DIR/Modules/"
    write_info_plist "$V_DIR/Resources/Info.plist" "macos"

    # Symlink-Struktur
    ln -s "A" "$FW_DIR/Versions/Current"
    ln -s "Versions/Current/$FRAMEWORK_NAME" "$FW_DIR/$FRAMEWORK_NAME"
    ln -s "Versions/Current/Headers" "$FW_DIR/Headers"
    ln -s "Versions/Current/Modules" "$FW_DIR/Modules"
    ln -s "Versions/Current/Resources" "$FW_DIR/Resources"

    install_name_tool -id "@rpath/$FRAMEWORK_NAME.framework/Versions/A/$FRAMEWORK_NAME" "$V_DIR/$FRAMEWORK_NAME" 2>/dev/null || true
}

DEVICE_DYLIB="target/aarch64-apple-ios/$TARGET_SUBDIR/lib${CRATE_NAME}.dylib"
SIM_DYLIB="target/aarch64-apple-ios-sim/$TARGET_SUBDIR/lib${CRATE_NAME}.dylib"
MAC_ARM_DYLIB="target/aarch64-apple-darwin/$TARGET_SUBDIR/lib${CRATE_NAME}.dylib"
MAC_X86_DYLIB="target/x86_64-apple-darwin/$TARGET_SUBDIR/lib${CRATE_NAME}.dylib"

for f in "$DEVICE_DYLIB" "$SIM_DYLIB" "$MAC_ARM_DYLIB" "$MAC_X86_DYLIB"; do
    if [ ! -f "$f" ]; then
        echo "FEHLER: $f nicht gefunden. Stelle sicher, dass Cargo.toml crate-type = [\"cdylib\"] enthaelt."
        exit 1
    fi
done

# macOS: Universal-Binary (arm64 + x86_64) via lipo
echo "==> Erstelle macOS-Universal-Binary (lipo)..."
MAC_UNIVERSAL_DYLIB="$STAGING_DIR/lib${CRATE_NAME}-macos-universal.dylib"
lipo -create "$MAC_ARM_DYLIB" "$MAC_X86_DYLIB" -output "$MAC_UNIVERSAL_DYLIB"

create_ios_framework "ios-arm64" "$DEVICE_DYLIB"
create_ios_framework "ios-arm64-simulator" "$SIM_DYLIB"
create_macos_framework "macos-universal" "$MAC_UNIVERSAL_DYLIB"

# Altes XCFramework loeschen
rm -rf "$OUTPUT_DIR"

# XCFramework aus den Framework-Bundles erstellen
echo "==> Erstelle XCFramework..."
xcodebuild -create-xcframework \
    -framework "$STAGING_DIR/ios-arm64/$FRAMEWORK_NAME.framework" \
    -framework "$STAGING_DIR/ios-arm64-simulator/$FRAMEWORK_NAME.framework" \
    -framework "$STAGING_DIR/macos-universal/$FRAMEWORK_NAME.framework" \
    -output "$OUTPUT_DIR"

# Aufraeumen
rm -rf "$HEADERS_DIR" "$STAGING_DIR" "$BINDGEN_OUT"

# Groessen anzeigen
DEVICE_SIZE=$(du -sh "$DEVICE_DYLIB" | cut -f1)
SIM_SIZE=$(du -sh "$SIM_DYLIB" | cut -f1)
MAC_SIZE=$(du -sh "$MAC_ARM_DYLIB" | cut -f1)

echo ""
echo "============================================="
echo " Fertig! (Dynamisches Framework, iOS + macOS)"
echo "============================================="
echo " XCFramework:    $OUTPUT_DIR"
echo " Swift-Bindings: $BINDINGS_TARGET_DIR/TypstNative.swift"
echo " FFI-Header:     $HEADER_TARGET_DIR/TypstNativeFFI.h"
echo ""
echo " Bibliotheks-Groessen:"
echo "   iOS Device (arm64):    $DEVICE_SIZE"
echo "   iOS Simulator (arm64): $SIM_SIZE"
echo "   macOS (arm64):         $MAC_SIZE"
echo ""
echo " Naechste Schritte:"
echo " 1. Konsumierende Projekte: Clean Build (Cmd+Shift+K, dann Cmd+B)"
echo "============================================="
