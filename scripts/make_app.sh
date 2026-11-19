#!/bin/bash
# PinClip .app 打包：swift build → 组装 bundle → ad-hoc 签名
set -euo pipefail
cd "$(dirname "$0")/.."

echo "▶ swift build (release)"
swift build -c release

APP="build/PinClip.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/PinClip "$APP/Contents/MacOS/PinClip"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleExecutable</key>
    <string>PinClip</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.pinclip.app</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>PinClip</string>
    <key>CFBundleDisplayName</key>
    <string>PinClip 贴剪</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.3</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>© 2026 PinClip · 全本地处理，不上传任何数据</string>
</dict>
</plist>
PLIST

echo "▶ codesign"
# 稳定签名优先：本地存在受信任的 "PinClip Dev" 证书时使用之（TCC 授权跨构建保留），
# 否则回退 ad-hoc（每次构建身份变化，需重新授权屏幕录制）
if security find-identity -v -p codesigning 2>/dev/null | grep -q "PinClip Dev"; then
    echo "  使用稳定签名身份: PinClip Dev"
    codesign --force --sign "PinClip Dev" "$APP"
else
    echo "  使用 ad-hoc 签名（未检测到 PinClip Dev 证书）"
    codesign --force --sign - "$APP"
fi

echo "✅ $APP"
