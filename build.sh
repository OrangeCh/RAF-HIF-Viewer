#!/bin/bash
# 构建 RAF-HIF 对照查看器.app
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APPNAME="RAF-HIF 对照查看器"
EXE="RAFHIFViewer"
BUNDLE_ID="local.rafhif.viewer"
VERSION="1.0"
TARGET_OS="14.0"

OUT="$ROOT/build"
APP="$OUT/$APPNAME.app"
BIN="$APP/Contents/MacOS/$EXE"

# SwiftUI 的 @State/@Observable 等宏由 libSwiftUIMacros.dylib 提供，该插件只在完整 Xcode 中。
# 若存在 Xcode 就切换工具链，否则显式指定插件路径。
XCODE_DEVELOPER="/Applications/Xcode.app/Contents/Developer"
PLUGIN_ARGS=()
if [ -d "$XCODE_DEVELOPER" ]; then
  export DEVELOPER_DIR="$XCODE_DEVELOPER"
  MACOS_PLUGINS="$XCODE_DEVELOPER/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins"
  [ -d "$MACOS_PLUGINS" ] && PLUGIN_ARGS=(-plugin-path "$MACOS_PLUGINS")
fi

echo "==> 清理"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> 编译 Swift 源码 (SDK $(xcrun --show-sdk-version), macOS $TARGET_OS+)"
xcrun swiftc \
  -O -whole-module-optimization \
  -swift-version 5 \
  -parse-as-library \
  -target "arm64-apple-macos$TARGET_OS" \
  ${PLUGIN_ARGS[@]+"${PLUGIN_ARGS[@]}"} \
  -framework SwiftUI -framework AppKit -framework ImageIO -framework CoreImage \
  "$ROOT/Sources/"*.swift \
  -o "$BIN"

echo "==> 拷贝本地化资源"
for lproj in "$ROOT/Resources/"*.lproj; do
  [ -d "$lproj" ] || continue
  name="$(basename "$lproj")"
  mkdir -p "$APP/Contents/Resources/$name"
  cp "$lproj"/*.strings "$APP/Contents/Resources/$name/" 2>/dev/null || true
  echo "    $name"
done

echo "==> 生成 Info.plist"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>$EXE</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>$APPNAME</string>
  <key>CFBundleDisplayName</key><string>$APPNAME</string>
  <key>CFBundleDevelopmentRegion</key><string>zh-Hans</string>
  <key>CFBundleLocalizations</key>
  <array><string>zh-Hans</string><string>en</string></array>
  <key>CFBundleAllowMixedLocalizations</key><true/>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>LSMinimumSystemVersion</key><string>$TARGET_OS</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.photography</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPhotoLibraryAddUsageDescription</key><string>把选中的照片加入「照片」App 的图库</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Fujifilm RAW</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSItemContentTypes</key><array><string>com.fuji.raw-image</string></array>
    </dict>
    <dict>
      <key>CFBundleTypeName</key><string>HEIF 图像</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSItemContentTypes</key><array><string>public.heic</string><string>public.heif</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> 代码签名（ad-hoc）"
codesign --force --sign - --timestamp=none "$APP" 2>&1 | sed 's/^/    /'

echo "==> 完成"
echo "    $(du -sh "$APP" | cut -f1)  $APP"
