#!/bin/sh
# Builds LabDock.app from the SwiftPM executable `LabDockApp` (no Xcode project):
#   Scripts/make-app.sh                  # release build → build/LabDock.app
#   CONFIG=debug Scripts/make-app.sh     # faster, debug build
#   Scripts/make-app.sh /Applications/LabDock.app
# The bundle: Contents/MacOS/LabDock (the executable), Contents/Info.plist
# (Bestchaan.LabDock, LSMinimumSystemVersion 26.0), Contents/Resources/AppIcon.icns;
# ad-hoc signed.
set -eu
cd "$(dirname "$0")/.."
config="${CONFIG:-release}"
app="${1:-build/LabDock.app}"
bundle_src="Sources/LabDockApp/Bundle"

# The compiler embeds source paths (#file, debug info) in the binary: map this checkout to "."
# so a published build carries no local paths (as LabDC does).
root="$(pwd)"
strip_paths="-Xswiftc -file-prefix-map -Xswiftc $root=. -Xcc -ffile-prefix-map=$root=. -Xcxx -ffile-prefix-map=$root=."
echo "make-app: swift build -c $config --product LabDockApp (local paths mapped to .)"
# shellcheck disable=SC2086
swift build -c "$config" --product LabDockApp $strip_paths
# shellcheck disable=SC2086
bin="$(swift build -c "$config" --show-bin-path $strip_paths)/LabDockApp"
[ -x "$bin" ] || { echo "make-app: $bin missing" >&2; exit 1; }

# Every build bumps the build number (owner, 3 Oct 2026: "1.0(1) 1.0(2) …"): the marketing
# version in Info.plist stays 1.0 until the owner changes it, CFBundleVersion counts up. The
# number lives in the source Info.plist, so the repo carries it across builds.
# KEEP_BUILD_NUMBER=1 (the release script, which sets the version itself) builds it unchanged.
build_number="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$bundle_src/Info.plist" 2>/dev/null || echo 0)"
if [ "${KEEP_BUILD_NUMBER:-0}" != "1" ]; then
    build_number=$((build_number + 1))
    plutil -replace CFBundleVersion -string "$build_number" "$bundle_src/Info.plist"
fi
short_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$bundle_src/Info.plist" 2>/dev/null || echo "1.0")"
echo "make-app: version $short_version ($build_number)"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/LabDock"
# A release build drops its debug symbol table: it lists every object file and source folder
# by absolute path (the linker's debug map), which the prefix map above does not reach.
if [ "$config" = "release" ]; then strip -S -x "$app/Contents/MacOS/LabDock"; fi
cp "$bundle_src/Info.plist" "$app/Contents/Info.plist"
plutil -lint "$app/Contents/Info.plist" >/dev/null || { echo "make-app: Info.plist is not a valid plist" >&2; exit 1; }
printf 'APPL????' > "$app/Contents/PkgInfo"

# AppIcon.icns from the 1024 px placeholder.
iconset="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$iconset"
for s in 16 32 128 256 512; do
    sips -z "$s" "$s" "$bundle_src/AppIcon.png" --out "$iconset/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2))
    sips -z "$d" "$d" "$bundle_src/AppIcon.png" --out "$iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns -o "$app/Contents/Resources/AppIcon.icns" "$iconset"
rm -rf "$(dirname "$iconset")"

# Sign with the owner's Apple Development identity (bestchaan@gmail.com) when it exists: its
# designated requirement is stable, so the Keychain stops asking "LabDock wants to use your
# confidential information" after every rebuild (an ad-hoc signature changes with each build and
# triggers that prompt every time). Falls back to the self-signed "LabDock Dev" cert made for
# the same reason, then to ad-hoc. SIGN_IDENTITY=… overrides the order.
preferred="${SIGN_IDENTITY:-}"
if [ -z "$preferred" ]; then
    preferred="$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/^ *[0-9]*) [0-9A-F]* "\(Apple Development:[^"]*\)"/\1/p' | head -1)"
fi

sign_with() {
    identity="$1"
    [ -n "$identity" ] || return 1
    security find-identity -v -p codesigning 2>/dev/null | grep -qF "\"$identity\"" || return 1
    codesign --force --sign "$identity" --timestamp=none "$app" >/dev/null 2>&1
}

if sign_with "$preferred"; then
    echo "make-app: signed as $preferred"
elif sign_with "LabDock Dev"; then
    echo "make-app: signed as LabDock Dev"
else
    codesign --force --sign - --timestamp=none "$app" >/dev/null 2>&1 || echo "make-app: ad-hoc signing failed (the app still runs locally)"
    echo "make-app: signed ad-hoc (no usable identity in the keychain)"
fi
echo "make-app: built $app (version $short_version, build $build_number)"
echo "make-app: open it with: open '$app'   (data: ~/Library/Application Support/LabDock)"
