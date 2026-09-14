#!/bin/bash
# Build Doki.app (menu-bar app + bundled bouncer + model + icon), ad-hoc sign it,
# and produce a drag-to-Applications DMG installer.
set -euo pipefail
cd "$(dirname "$0")/.."

DIST=dist
APP="$DIST/Doki.app"
ICON_DIR=packaging/icon
echo "==> swift build -c release"
swift build -c release >/dev/null

rm -rf "$DIST"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> assembling bundle"
cp .build/release/Doki  "$APP/Contents/MacOS/Doki"
cp .build/release/bouncer "$APP/Contents/MacOS/bouncer"
cp bounce-model.json      "$APP/Contents/Resources/bounce-model.json"
cp packaging/Info.plist   "$APP/Contents/Info.plist"

echo "==> icon (prebuilt kawaii set: $ICON_DIR)"
iconutil -c icns "$ICON_DIR/Doki.iconset" -o "$APP/Contents/Resources/Doki.icns"
cp "$ICON_DIR/DokiMenuTemplate.png" "$ICON_DIR/DokiMenuTemplate@2x.png" \
   "$APP/Contents/Resources/"

echo "==> codesign (stable self-signed identity → Accessibility grant survives rebuilds)"
KC="$PWD/packaging/doki-sign.keychain-db"
if security find-certificate -c "Doki Self-Signed" "$KC" >/dev/null 2>&1; then
    security unlock-keychain -p Doki "$KC" 2>/dev/null || true
    codesign --force --deep --options runtime --sign "Doki Self-Signed" --keychain "$KC" "$APP"
    codesign -dvv "$APP" 2>&1 | grep -i Authority | head -1
else
    echo "   (no stable identity — run packaging/sign-setup.sh first; falling back to ad-hoc)"
    codesign --force --deep --sign - "$APP" 2>/dev/null || true
fi

echo "==> DMG (drag Doki → Applications)"
if command -v create-dmg >/dev/null 2>&1; then
    # Retina background: Finder only honors @2x via a multi-page TIFF.
    BG="$DIST/dmg-bg.tiff"
    tiffutil -cathidpicheck "$ICON_DIR/dmg_background.png" \
                            "$ICON_DIR/dmg_background@2x.png" \
                            -out "$BG" 2>/dev/null \
        || BG="$ICON_DIR/dmg_background.png"
    rm -f "$DIST/Doki.dmg"
    create-dmg \
        --volname "Doki" \
        --volicon "$APP/Contents/Resources/Doki.icns" \
        --background "$BG" \
        --window-size 600 400 \
        --icon-size 128 \
        --icon "Doki.app" 150 190 \
        --app-drop-link 450 190 \
        --no-internet-enable \
        "$DIST/Doki.dmg" \
        "$APP" >/dev/null
    rm -f "$DIST/dmg-bg.tiff"
else
    echo "   (create-dmg not found — plain DMG; 'brew install create-dmg' for the kawaii one)"
    STAGE="$DIST/stage"; mkdir -p "$STAGE"
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    hdiutil create -volname "Doki" -srcfolder "$STAGE" -ov -format UDZO "$DIST/Doki.dmg" >/dev/null
    rm -rf "$STAGE"
fi

echo "==> done:"
echo "    $APP"
echo "    $DIST/Doki.dmg"
