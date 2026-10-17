#!/bin/bash
# Builds the app extensions into build/PlugIns (picked up by build-app.sh). Uses swiftc directly
# because SwiftPM cannot produce .appex bundles.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
OUT="$ROOT/build/PlugIns"; rm -rf "$OUT"; mkdir -p "$OUT"
SDK="$(xcrun --show-sdk-path)"; ARCH="$(uname -m)"; MIN=14.0
APP_ID=com.udsy.superscreenshot

# make_appex <name> <display> <point-id> <principal-class> <attributes-xml> <flags> <sources...>
make_appex() {
  local name="$1" display="$2" point="$3" principal="$4" attrs="$5" flags="$6"; shift 6
  local dir="$OUT/$name.appex/Contents"
  mkdir -p "$dir/MacOS"
  local archs=("$ARCH"); [ "${UNIVERSAL:-0}" = 1 ] && archs=(arm64 x86_64)
  local slices=()
  for a in "${archs[@]}"; do
    # shellcheck disable=SC2086
    swiftc -O -module-name "$name" -target "$a-apple-macos$MIN" -sdk "$SDK" -application-extension $flags \
      -Xlinker -e -Xlinker _NSExtensionMain -o "$dir/MacOS/$name.$a" "$@"
    slices+=("$dir/MacOS/$name.$a")
  done
  lipo -create -output "$dir/MacOS/$name" "${slices[@]}" && rm -f "${slices[@]}"
  cat > "$dir/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleDisplayName</key><string>$display</string>
  <key>CFBundleExecutable</key><string>$name</string>
  <key>CFBundleIdentifier</key><string>$APP_ID.$name</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>$name</string>
  <key>CFBundlePackageType</key><string>XPC!</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>$MIN</string>
  <key>NSExtension</key><dict>
    <key>NSExtensionAttributes</key><dict>$attrs</dict>
    <key>NSExtensionPointIdentifier</key><string>$point</string>
    <key>NSExtensionPrincipalClass</key><string>$name.$principal</string>
  </dict>
</dict></plist>
PLIST
}

IMAGE_RULE='<key>NSExtensionActivationRule</key><string>SUBQUERY(extensionItems, $item, SUBQUERY($item.attachments, $a, ANY $a.registeredTypeIdentifiers UTI-CONFORMS-TO "public.image").@count == 1).@count == 1</string>'
make_appex AnnotateShareExtension "Annotate with Super Screenshot" com.apple.share-services ShareViewController "$IMAGE_RULE" "" Extensions/Share/ShareViewController.swift
make_appex PinShareExtension "Pin to the Screen" com.apple.share-services ShareViewController "$IMAGE_RULE" "-D PIN" Extensions/Share/ShareViewController.swift

if [ -d Extensions/QuickLook ]; then
  # Current document types plus the ones saved before the rename from Shotcraft.
  DOC_TYPES='<string>com.udsy.superscreenshot.document</string><string>com.udsy.superscreenshot.videoproject</string>'
  DOC_TYPES+='<string>com.udsy.shotcraft.document</string><string>com.udsy.shotcraft.videoproject</string>'
  QL_TYPES='<key>QLSupportedContentTypes</key><array>'"$DOC_TYPES"'</array><key>QLSupportsSearchableItems</key><false/><key>QLIsDataBasedPreview</key><true/>'
  make_appex QuickLookExtension "Super Screenshot Preview" com.apple.quicklook.preview PreviewProvider "$QL_TYPES" "" Extensions/QuickLook/Shared.swift Extensions/QuickLook/PreviewProvider.swift
  TH_TYPES='<key>QLSupportedContentTypes</key><array>'"$DOC_TYPES"'</array><key>QLThumbnailMinimumDimension</key><integer>0</integer>'
  make_appex QuickLookThumbnailingExtension "Super Screenshot Thumbnails" com.apple.quicklook.thumbnail ThumbnailProvider "$TH_TYPES" "" Extensions/QuickLook/Shared.swift Extensions/QuickLook/ThumbnailProvider.swift
fi
echo "Built extensions in $OUT"
