#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

echo "==> Generating Xcode project..."
xcodegen generate

DERIVED_DATA="$ROOT_DIR/.deriveddata"
DIST_DIR="$ROOT_DIR/dist"
APP_NAME="Pixeldrain Downloader.app"

echo "==> Building Release app..."
xcodebuild \
    -project PixeldrainDownloader.xcodeproj \
    -scheme PixeldrainDownloader \
    -configuration Release \
    -derivedDataPath "$DERIVED_DATA" \
    build

BUILT_APP="$DERIVED_DATA/Build/Products/Release/$APP_NAME"
if [[ ! -d "$BUILT_APP" ]]; then
    echo "Error: built app not found at $BUILT_APP" >&2
    exit 1
fi

rm -rf "$DIST_DIR/$APP_NAME"
mkdir -p "$DIST_DIR"
ditto "$BUILT_APP" "$DIST_DIR/$APP_NAME"

TARGET_APP="$DIST_DIR/$APP_NAME"
HELPERS_DIR="$TARGET_APP/Contents/Helpers"
FRAMEWORKS_DIR="$TARGET_APP/Contents/Frameworks"

if ARIA2_SRC="$(command -v aria2c 2>/dev/null)"; then
    echo "==> Bundling aria2c from $ARIA2_SRC..."
    mkdir -p "$HELPERS_DIR" "$FRAMEWORKS_DIR"
    cp -f "$ARIA2_SRC" "$HELPERS_DIR/aria2c"
    chmod 755 "$HELPERS_DIR/aria2c"

    # Copy non-system dylibs (Homebrew / MacPorts) and rewrite install names using Apple's toolchain
    copy_deps() {
        local binary="$1"
        local dep=""
        while IFS= read -r dep; do
            [[ -z "$dep" ]] && continue
            if [[ "$dep" == /opt/homebrew/* || "$dep" == /usr/local/* ]]; then
                local base
                base="$(basename "$dep")"
                local dest="$FRAMEWORKS_DIR/$base"
                if [[ ! -f "$dest" ]]; then
                    cp -f "$dep" "$dest"
                    chmod 755 "$dest"
                    /usr/bin/install_name_tool -id "@rpath/$base" "$dest"
                    copy_deps "$dest"
                fi
                if [[ "$binary" == "$HELPERS_DIR/aria2c" ]]; then
                    /usr/bin/install_name_tool -change "$dep" "@executable_path/../Frameworks/$base" "$binary"
                else
                    /usr/bin/install_name_tool -change "$dep" "@loader_path/$base" "$binary"
                fi
            fi
        done < <(/usr/bin/otool -L "$binary" | tail -n +2 | awk '{print $1}')
    }

    copy_deps "$HELPERS_DIR/aria2c"

    # Re-sign bundled dylibs and aria2c after install_name_tool edits
    for dylib in "$FRAMEWORKS_DIR"/*.dylib; do
        [[ -e "$dylib" ]] && /usr/bin/codesign --force --sign - "$dylib"
    done
    /usr/bin/codesign --force --sign - "$HELPERS_DIR/aria2c"
else
    echo "Warning: aria2c not found in PATH; app will look for system aria2c at runtime." >&2
fi

echo "==> Ad-hoc signing $TARGET_APP..."
/usr/bin/codesign --force --deep --sign - "$TARGET_APP"

echo "==> Verifying bundled aria2c..."
if [[ -x "$HELPERS_DIR/aria2c" ]]; then
    "$HELPERS_DIR/aria2c" --version | head -n 2
fi

echo ""
echo "Built: $TARGET_APP"
echo "To install to /Applications:"
echo "  cp -R \"$TARGET_APP\" /Applications/"
