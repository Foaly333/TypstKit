#!/usr/bin/env bash
# Installiert mo-tools als @local-Paket für die Typst-CLI.
set -euo pipefail
VERSION="0.1.0"
case "$(uname)" in
  Darwin) BASE="$HOME/Library/Application Support/typst/packages" ;;
  *)      BASE="${XDG_DATA_HOME:-$HOME/.local/share}/typst/packages" ;;
esac
ZIEL="$BASE/local/mo-tools/$VERSION"
mkdir -p "$ZIEL"
cp "$(dirname "$0")"/{typst.toml,lib.typ,kontrakt.typ,elemente.typ} "$ZIEL/"
echo "mo-tools $VERSION installiert nach: $ZIEL"
