#!/bin/zsh
# Builds the Mac App Store flavour (configuration MAS) and exports the .pkg for App Store Connect. Holds no credentials; they come in
# as variables, and the upload is printed, not run.
#
#   scripts/mas.sh                # → build/mas/export/Mwoyeo.pkg
#
# Needs, on the release Mac:
#   MWOYEO_MAS_IDENTITY   "Apple Distribution: Name (TEAMID)"
#   MWOYEO_MAS_PROFILE    the name of the Mac App Store provisioning profile of dev.midagedev.mwoyeo.appstore
#   MWOYEO_MAS_INSTALLER  optional, the installer certificate (default "3rd Party Mac Developer Installer")
#   MWOYEO_MAS_VERSION    optional, the version (default: the newest v* tag, as the GitHub release takes it from its tag)
#   xcodegen
set -euo pipefail

ROOT=${0:A:h:h}
OUT=$ROOT/build/mas
APP_ID=dev.midagedev.mwoyeo.appstore
IDENTITY=${MWOYEO_MAS_IDENTITY:?set MWOYEO_MAS_IDENTITY to your Apple Distribution identity}
PROFILE=${MWOYEO_MAS_PROFILE:?set MWOYEO_MAS_PROFILE to the name of the Mac App Store provisioning profile}
INSTALLER=${MWOYEO_MAS_INSTALLER:-3rd Party Mac Developer Installer}
TEAM=${IDENTITY##*\(}; TEAM=${TEAM%\)}
VERSION=${MWOYEO_MAS_VERSION:-$(git -C "${0:A:h:h}" describe --tags --abbrev=0 --match 'v*')}; VERSION=${VERSION#v}
[[ "$TEAM" != "$IDENTITY" && -n "$TEAM" ]] || { echo "MWOYEO_MAS_IDENTITY must end in the team id: \"Apple Distribution: Name (TEAMID)\"" >&2; exit 1; }

cd "$ROOT"
[[ -d tools/inpaint/models/MIGAN_512.mlpackage ]] || { echo "missing tools/inpaint/models/MIGAN_512.mlpackage" >&2; exit 1; }

echo "==> Archive"
rm -rf "$OUT"; mkdir -p "$OUT"
xcodegen generate >/dev/null
xcodebuild -project Mwoyeo.xcodeproj -scheme Mwoyeo-MAS -configuration MAS -destination 'generic/platform=macOS' \
  -archivePath "$OUT/Mwoyeo.xcarchive" -derivedDataPath "$OUT/dd" \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$(git rev-list --count HEAD)" \
  MWOYEO_SIGN_IDENTITY="$IDENTITY" MWOYEO_TEAM="$TEAM" MWOYEO_PROFILE="$PROFILE" \
  archive > "$OUT/archive.log" 2>&1 || { tail -30 "$OUT/archive.log"; exit 1; }
APP=$OUT/Mwoyeo.xcarchive/Products/Applications/Mwoyeo.app
codesign --verify --strict --deep --verbose=2 "$APP"
# The app and each reader service (Contents/XPCServices/*.xpc) are signed on their own, and the store rejects any of them with get-task-allow.
SERVICES=("$APP"/Contents/XPCServices/*.xpc(N))
(( ${#SERVICES} > 0 )) || { echo "the app embeds no reader services (Contents/XPCServices)" >&2; exit 1; }
for BUNDLE in "$APP" "${SERVICES[@]}"; do
  ! codesign -d --entitlements - "$BUNDLE" 2>/dev/null | grep -q get-task-allow ||
    { echo "${BUNDLE:t} is signed with get-task-allow, which the store rejects" >&2; exit 1; }
  echo "no get-task-allow: ${BUNDLE:t}"
done
[[ -d "$APP/Contents/Resources/MIGAN_512.mlmodelc" ]] || { echo "the app has no inpainting model" >&2; exit 1; }

echo "==> Export"
sed -e "s|__TEAM__|$TEAM|" -e "s|__APP_ID__|$APP_ID|" -e "s|__PROFILE__|$PROFILE|" \
    -e "s|<string>3rd Party Mac Developer Installer</string>|<string>$INSTALLER</string>|" \
    scripts/ExportOptions-MAS.plist > "$OUT/ExportOptions.plist"
xcodebuild -exportArchive -archivePath "$OUT/Mwoyeo.xcarchive" -exportPath "$OUT/export" -exportOptionsPlist "$OUT/ExportOptions.plist" \
  > "$OUT/export.log" 2>&1 || { tail -30 "$OUT/export.log"; exit 1; }
PKG=("$OUT"/export/*.pkg(N))
(( ${#PKG} == 1 )) || { echo "export wrote no single .pkg in $OUT/export" >&2; exit 1; }
echo "$PKG"
echo "Upload (not run here), with an App Store Connect API key:"
echo "  xcrun altool --upload-package \"$PKG\" --platform macos --apple-id <app apple id> --bundle-id $APP_ID --bundle-version <build> --bundle-short-version-string <version> --apiKey <key id> --apiIssuer <issuer id>"
echo "  or open the .pkg in Transporter."
