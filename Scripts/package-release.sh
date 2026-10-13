#!/usr/bin/env bash
# Build release artifacts: .app zip + source checksum helpers.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-1.2.0}"
DIST="${ROOT}/dist"
APP_NAME="SuperGrokBar"
STAGE="${DIST}/stage"
APP_DIR="${STAGE}/${APP_NAME}.app"

cd "$ROOT"
rm -rf "$DIST"
mkdir -p "$STAGE"

echo "→ Building ${APP_NAME} v${VERSION}…"
swift build -c release --product SuperGrokBar
BIN="$(swift build -c release --show-bin-path)/SuperGrokBar"
BUNDLE="$(dirname "$BIN")/SuperGrokBar_SuperGrokBar.bundle"

mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources"
cp "$BIN" "${APP_DIR}/Contents/MacOS/${APP_NAME}"
chmod +x "${APP_DIR}/Contents/MacOS/${APP_NAME}"

if [[ -d "$BUNDLE" ]]; then
  cp -R "$BUNDLE" "${APP_DIR}/Contents/Resources/"
  find "$BUNDLE" -type f \( -name '*.png' -o -name '*.svg' -o -name 'ATTRIBUTION.txt' \) \
    -exec cp {} "${APP_DIR}/Contents/Resources/" \;
elif [[ -d "${ROOT}/Sources/SuperGrokBar/Resources" ]]; then
  cp -R "${ROOT}/Sources/SuperGrokBar/Resources/." "${APP_DIR}/Contents/Resources/"
fi

cat > "${APP_DIR}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key>
  <string>com.kujira.SuperGrokBar</string>
  <key>CFBundleName</key>
  <string>SuperGrok Bar</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${VERSION}</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>NSSupportsAutomaticTermination</key>
  <false/>
  <key>NSSupportsSuddenTermination</key>
  <false/>
</dict>
</plist>
PLIST
echo -n 'APPL????' > "${APP_DIR}/Contents/PkgInfo"

# Include install helper next to the app in the zip
cp "${ROOT}/Scripts/supergrok-bar" "${STAGE}/install-supergrok-bar"
chmod +x "${STAGE}/install-supergrok-bar"
cat > "${STAGE}/README.txt" <<EOF
SuperGrok Bar v${VERSION}

1. Double-click SuperGrokBar.app, or run:
     ./install-supergrok-bar
2. Ensure you have logged in with: grok login
3. Look for the Grok mark + usage % in the menu bar.

Requires macOS 14+ and Apple Silicon or Intel Mac.
EOF

(
  cd "$STAGE"
  ditto -c -k --sequesterRsrc --keepParent "${APP_NAME}.app" \
    "${DIST}/${APP_NAME}-${VERSION}-macos.zip"
)

# Also ship a tarball of source via git archive after tag (release workflow)
echo "→ Artifacts:"
ls -la "$DIST"
shasum -a 256 "${DIST}/${APP_NAME}-${VERSION}-macos.zip" | tee "${DIST}/SHA256SUMS"
echo "done"
