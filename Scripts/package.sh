#!/bin/bash
# OsmoVault 打包脚本：把 release 二进制封装成 .app 并分发到 dist / ~/Applications / ~/Desktop
set -euo pipefail

PROJ="/Users/hubzy/Documents/New project/OsmoVault"
BIN="$PROJ/.build/release/OsmoVault"
STAGE="$PROJ/.build/OsmoVault.app"
DIST="$PROJ/dist/OsmoVault.app"

cd "$PROJ"
echo "==> 编译 release"
# 必须 --disable-sandbox：SPM 解析 manifest 时会 fork sandbox-exec，在受限环境下会失败
swift build -c release --disable-sandbox

echo "==> 组装 App Bundle"
rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$BIN" "$STAGE/Contents/MacOS/OsmoVault"
cp "$PROJ/Resources/Info.plist" "$STAGE/Contents/Info.plist"
cp "$PROJ/Resources/AppIcon.icns" "$STAGE/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$STAGE/Contents/PkgInfo"
find "$STAGE" -name '.DS_Store' -delete

echo "==> ad-hoc 签名"
codesign --force --deep --sign - "$STAGE" >/dev/null
codesign --verify --deep --strict "$STAGE" && echo "签名校验通过"

install_app() {
  local dst="$1"
  rm -rf "$dst"
  mkdir -p "$(dirname "$dst")"
  cp -R "$STAGE" "$dst"
  xattr -dr com.apple.quarantine "$dst" 2>/dev/null || true
  echo "已安装 -> $dst"
}

echo "==> 分发"
rm -rf "$DIST"; mkdir -p "$(dirname "$DIST")"; cp -R "$STAGE" "$DIST"
install_app "$HOME/Applications/OsmoVault.app"
install_app "$HOME/Desktop/OsmoVault.app"

echo "==> 完成"
