#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h}"
ARCH="${ARCH:-$(uname -m)}"
case "$ARCH" in arm64|x86_64) ;; *) echo "Unsupported architecture: $ARCH" >&2; exit 1 ;; esac
APP="$ROOT/dist/NetworkLens.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun swiftc -swift-version 5 -O -target "$ARCH-apple-macosx13.0" \
  "$ROOT/Sources/Core.swift" "$ROOT/Sources/App.swift" "$ROOT/Tests/SelfTests.swift" \
  -framework AppKit -framework SwiftUI -framework Network -framework Charts \
  -framework UserNotifications -framework ServiceManagement \
  -o "$APP/Contents/MacOS/NetworkLens"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>NetworkLens</string>
<key>CFBundleIdentifier</key><string>local.networklens.desktop</string>
<key>CFBundleName</key><string>NetworkLens</string>
<key>CFBundleDisplayName</key><string>网络透镜</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleVersion</key><string>2</string>
<key>CFBundleShortVersionString</key><string>1.1.0</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSLocalNetworkUsageDescription</key><string>网络透镜需要探测本地默认网关及你配置的内网站点，以区分本机、公司网络与远程服务异常。</string>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoads</key><true/></dict>
<key>NSHumanReadableCopyright</key><string>Local-first network diagnostics.</string>
</dict></plist>
PLIST
cp "$ROOT/Assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
echo "Built: $APP"
