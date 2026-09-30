#!/usr/bin/env bash
# ============================================================================
# Release gate: no icon-font drift against a real Shorebird release.
# ============================================================================
# WHY THIS EXISTS
#   Shorebird cannot ship an ASSET change in a patch, and the MaterialIcons
#   font is an asset. So one icon glyph that the shipped font does not contain
#   blocks every patch. The symptom is a wall of Gradle output ending in
#   "Your app contains asset changes", which does not say WHICH icon.
#
#   Diffing against git history is not good enough. The real baseline is the
#   font inside the PUBLISHED release artifact, and it can differ from what any
#   commit implies - release 1.1.0+9 shipped code referencing Icons.done_all
#   while its own font lacked that glyph, which is how a blank "Mark all as
#   read" button reached users.
#
# USAGE
#   tool/verify_icons_against_release_font.sh              # uses 1.1.0+9
#   tool/verify_icons_against_release_font.sh 1.1.1+10    # after a new release
#
# Requires: python3, unzip, and a release build already produced by
# `flutter build aab --release`.
set -euo pipefail

RELEASE="${1:-1.1.0+9}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FONT_PATH="base/assets/flutter_assets/fonts/MaterialIcons-Regular.otf"
SDK_ICONS="$(find "$HOME/.shorebird/bin/cache/flutter" -path '*material/icons.dart' 2>/dev/null | head -1)"
BUILT_FONT="$ROOT/build/app/intermediates/flutter/release/flutter_assets/fonts/MaterialIcons-Regular.otf"
REFERENCE="$ROOT/test/assets/release_$(echo "$RELEASE" | tr '+.+' '__')_MaterialIcons-Regular.otf"

if [[ ! -f "$BUILT_FONT" ]]; then
  echo "No release build found. Run: flutter build aab --release" >&2
  exit 1
fi

# The committed reference is the fast path and the CI-friendly one.
if [[ ! -f "$REFERENCE" ]]; then
  echo "No committed reference for $RELEASE at:"
  echo "  $REFERENCE"
  echo
  echo "To create it, download that release's AAB and extract the font:"
  echo "  shorebird releases get-apks --release-version $RELEASE"
  echo "  unzip -p app-release.aab $FONT_PATH > \"$REFERENCE\""
  exit 1
fi

echo "Baseline font : $REFERENCE  ($RELEASE)"
echo "Built font    : $BUILT_FONT"

if [[ -z "$SDK_ICONS" ]]; then
  echo
  echo "WARNING: could not find the Flutter SDK icons.dart, so codepoints will"
  echo "         not be named. Falling back to a raw codepoint diff."
  echo
  python3 "$ROOT/tool/icon_font_diff.py" "$REFERENCE" "$BUILT_FONT"
else
  python3 "$ROOT/tool/icon_font_diff.py" \
    "$REFERENCE" "$BUILT_FONT" --names "$SDK_ICONS"
fi

# An ADDED glyph is what blocks a patch. A REMOVED one is fine and expected:
# dropping an unreferenced glyph is a reduction, not a new asset.
ADDED="$(python3 "$ROOT/tool/icon_font_diff.py" "$REFERENCE" "$BUILT_FONT" \
  | sed -n 's/^ADDED (\([0-9]*\)).*/\1/p')"

echo
if [[ "$ADDED" != "0" ]]; then
  echo "FAIL: $ADDED glyph(s) added. A patch would be BLOCKED by the asset diff."
  echo "      Fix with: python3 tool/map_icons_to_shipped_font.py"
  exit 1
fi

echo "PASS: no glyph added, so the icon font is unchanged and a patch can apply."
