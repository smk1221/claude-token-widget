#!/bin/bash
# 构建 Claude Token 用量小组件,并安装到 ~/Applications(Spotlight / 启动台可搜到)
set -e
cd "$(dirname "$0")"

APP="TokenWidget.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/"
cp AppIcon.icns "$APP/Contents/Resources/" 2>/dev/null || true

swiftc -O -parse-as-library TokenWidget.swift -o "$APP/Contents/MacOS/TokenWidget"
codesign --force --sign - "$APP" 2>/dev/null || true

mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/TokenWidget.app"
cp -R "$APP" "$HOME/Applications/"

echo "✅ 构建完成,已安装到 ~/Applications/TokenWidget.app"
