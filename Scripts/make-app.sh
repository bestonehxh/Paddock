#!/bin/sh
# Builds Paddock.app from the SwiftPM executable `PaddockApp` (no Xcode project):
#   Scripts/make-app.sh                  # release build → build/Paddock.app
#   CONFIG=debug Scripts/make-app.sh     # faster, debug build
#   Scripts/make-app.sh /Applications/Paddock.app
# The bundle: Contents/MacOS/Paddock (the executable), Contents/Info.plist
# (Bestchaan.Paddock, LSMinimumSystemVersion 26.0), Contents/Resources/AppIcon.icns;
# ad-hoc signed.
set -eu
cd "$(dirname "$0")/.."
config="${CONFIG:-release}"
app="${1:-build/Paddock.app}"
bundle_src="Sources/PaddockApp/Bundle"

# The compiler embeds source paths (#file, debug info) in the binary: map this checkout to "."
# so a published build carries no local paths (as LabDC does).
root="$(pwd)"
strip_paths="-Xswiftc -file-prefix-map -Xswiftc $root=. -Xcc -ffile-prefix-map=$root=. -Xcxx -ffile-prefix-map=$root=."
echo "make-app: swift build -c $config --product PaddockApp (local paths mapped to .)"
# shellcheck disable=SC2086
swift build -c "$config" --product PaddockApp $strip_paths
# shellcheck disable=SC2086
bin="$(swift build -c "$config" --show-bin-path $strip_paths)/PaddockApp"
[ -x "$bin" ] || { echo "make-app: $bin missing" >&2; exit 1; }

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/Paddock"
# A release build drops its debug symbol table: it lists every object file and source folder
# by absolute path (the linker's debug map), which the prefix map above does not reach.
if [ "$config" = "release" ]; then strip -S -x "$app/Contents/MacOS/Paddock"; fi
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

# Sign with the local "Paddock Dev" identity when it exists (a self-signed code-signing cert in
# the login keychain, made 3 Oct 2026): its designated requirement is stable, so the Keychain
# stops asking "Paddock wants to use your confidential information" after every rebuild. An
# ad-hoc signature changes with each build and triggers that prompt every time.
identity="${SIGN_IDENTITY:-Paddock Dev}"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$identity\"" \
   && codesign --force --sign "$identity" --timestamp=none "$app" >/dev/null 2>&1; then
    echo "make-app: signed as $identity"
else
    codesign --force --sign - --timestamp=none "$app" >/dev/null 2>&1 || echo "make-app: ad-hoc signing failed (the app still runs locally)"
    echo "make-app: signed ad-hoc (no '$identity' identity in the keychain)"
fi
echo "make-app: built $app"
echo "make-app: open it with: open '$app'   (data: ~/Library/Application Support/Paddock)"
