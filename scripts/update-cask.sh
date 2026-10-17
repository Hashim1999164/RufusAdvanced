#!/bin/bash
# Update the Homebrew tap (github.com/Hashim1999164/homebrew-tap) to a published release.
#
#   scripts/update-cask.sh 1.1.0 [path/to/homebrew-tap]
#
# Reads the DMG checksum from the release's SHA256SUMS.txt, renders Packaging/homebrew/rufusadvanced.rb.in
# into <tap>/Casks/rufusadvanced.rb and commits it. Push the tap afterwards.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:?usage: scripts/update-cask.sh <version> [tap checkout]}"
TAP="${2:-../homebrew-tap}"
DMG="RufusAdvanced-$VERSION-macOS.dmg"
SUMS_URL="https://github.com/Hashim1999164/RufusAdvanced/releases/download/v$VERSION/SHA256SUMS.txt"

SHA="$(curl -fsSL "$SUMS_URL" | awk -v f="$DMG" '$2 == f || $2 == "*" f {print $1}')"
[ -n "$SHA" ] || { echo "No checksum for $DMG in $SUMS_URL" >&2; exit 1; }
[ -d "$TAP/.git" ] || git clone https://github.com/Hashim1999164/homebrew-tap.git "$TAP"

mkdir -p "$TAP/Casks"
sed -e "s/@VERSION@/$VERSION/" -e "s/@SHA256@/$SHA/" Packaging/homebrew/rufusadvanced.rb.in > "$TAP/Casks/rufusadvanced.rb"
git -C "$TAP" add Casks/rufusadvanced.rb
git -C "$TAP" commit -m "rufusadvanced $VERSION"
echo "Updated $TAP/Casks/rufusadvanced.rb to $VERSION ($SHA). Push it with: git -C $TAP push"
