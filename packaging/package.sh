#!/bin/zsh
# Build rilis self-contained: app menu bar + Python runtime + daemon + libopus → DMG.
# Hasil: dist/DiscordVoiceLite-<versi>.dmg (Apple Silicon / arm64).
set -euo pipefail
ROOT="${0:A:h:h}"
cd "$ROOT"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" menubar/Info.plist)
WORK=dist/work
APP="$WORK/Discord Voice Lite.app"
RES="$APP/Contents/Resources"
DMG="dist/DiscordVoiceLite-$VERSION.dmg"
PYTHON_SRC=$(readlink -f "$(cd daemon && uv python find --managed-python 3.14)" | xargs dirname | xargs dirname)
OPUS_SRC=$(brew --prefix opus)/lib/libopus.0.dylib

rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$RES"/{daemon,lib}

echo "==> App binary"
cp menubar/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Delete :DLDaemonDir" -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist"
swiftc -O -swift-version 5 -target arm64-apple-macos13.0 \
  -framework AppKit -framework Security -framework AVFoundation \
  -o "$APP/Contents/MacOS/DiscordVoiceLite" menubar/Sources/*.swift

echo "==> Icon"
swift packaging/make-icon.swift "$WORK"
iconutil -c icns "$WORK/AppIcon.iconset" -o "$RES/AppIcon.icns"

echo "==> Python runtime ($PYTHON_SRC)"
cp -R "$PYTHON_SRC" "$RES/python"
PY="$RES/python/bin/python3"
# Buang bagian runtime yang tidak dipakai daemon.
rm -rf "$RES/python/include" "$RES/python/share"
for d in test idlelib tkinter turtledemo ensurepip lib2to3 pydoc_data; do
  rm -rf "$RES/python/lib/python3.14/$d"
done
setopt local_options null_glob
rm -rf "$RES/python/lib"/{libtcl,libtk,tcl,tk,itcl,thread}* "$RES/python/lib/python3.14/lib-dynload"/_tkinter*
rm -f "$RES/python/lib/python3.14/EXTERNALLY-MANAGED"

echo "==> Dependencies"
(cd daemon && uv export --frozen --no-hashes --no-dev --no-emit-project) > "$WORK/requirements.txt"
uv pip install --python "$PY" --break-system-packages --no-cache -r "$WORK/requirements.txt" >/dev/null
uv pip uninstall --python "$PY" --break-system-packages mypy-protobuf types-protobuf >/dev/null 2>&1 || true
find "$RES/python" -name "__pycache__" -type d -prune -exec rm -rf {} +

echo "==> Daemon + libopus"
cp daemon/discordlight.py "$RES/daemon/"
cp "$OPUS_SRC" "$RES/lib/libopus.0.dylib"
install_name_tool -id @loader_path/libopus.0.dylib "$RES/lib/libopus.0.dylib" 2>/dev/null

echo "==> Precompile bytecode"
"$PY" -m compileall -q -j 0 "$RES/python/lib/python3.14" "$RES/daemon" >/dev/null || true

echo "==> Codesign (ad-hoc)"
# Sign semua Mach-O di dalam bundle dulu (dalam → luar), lalu bundle-nya.
find "$RES" -type f \( -name "*.so" -o -name "*.dylib" -o -perm -u+x \) -print0 |
  while IFS= read -r -d '' f; do
    if file -b "$f" | grep -q "Mach-O"; then codesign --force --sign - "$f" 2>/dev/null; fi
  done
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"

echo "==> Smoke test daemon"
SMOKE=$(printf '' | "$PY" -s "$RES/daemon/discordlight.py" "$WORK/smoke.sock" 2>&1 | head -1)
[[ "$SMOKE" == *need_token* ]] || { echo "Daemon smoke test gagal: $SMOKE"; exit 1; }

echo "==> DMG"
STAGE="$WORK/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Discord Voice Lite" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null

du -sh "$APP" "$DMG"
echo "Selesai: $DMG"
