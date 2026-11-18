#!/bin/bash
# 打包成可分发安装包（DMG + PKG），通用二进制，Intel / Apple 芯片都能装
# 用法： ./package.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAME="KesonMount"
BUNDLE_ID="com.keson.kesonmount"
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$ROOT/Resources/Info.plist")"
WORK="${TMPDIR:-/tmp}/kesonmount-package"
APP="$WORK/$NAME.app"
OUT="$ROOT/dist"

rm -rf "$WORK"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$OUT"

echo "▶ 编译通用二进制（arm64 + x86_64）…"
# 先在本地临时目录拷一份再编译：工程放在 SMB 卷上时，文件 mtime 抖动会让
# swiftc 报「input file … was modified during the build」直接失败。
SRC="$WORK/src/Sources"
ditto "$ROOT/Sources" "$SRC"
# 不要重定向掉 swiftc 的报错：编译失败时用户只会看到后面 lipo 的「文件不存在」，
# 真正的原因（缺少 import、API 变更）全被吞了
swiftc -O -swift-version 5 -target arm64-apple-macos14.0 \
  -framework AppKit -framework WebKit -framework Foundation -framework Network \
  -framework UserNotifications -framework ServiceManagement \
  "$SRC"/*.swift -o "$WORK/KesonMount-arm64"
swiftc -O -swift-version 5 -target x86_64-apple-macos14.0 \
  -framework AppKit -framework WebKit -framework Foundation -framework Network \
  -framework UserNotifications -framework ServiceManagement \
  "$SRC"/*.swift -o "$WORK/KesonMount-x86_64"
lipo -create -output "$APP/Contents/MacOS/KesonMount" \
  "$WORK/KesonMount-arm64" "$WORK/KesonMount-x86_64"
lipo -info "$APP/Contents/MacOS/KesonMount"

echo "▶ 组装应用…"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/ui.html" "$APP/Contents/Resources/ui.html"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
# 内置使用说明书（菜单「帮助 → 使用说明书」读它）
# 按 Info.plist 里的版本号精确取对应那份，别再按 mtime 猜——
# 旧 PDF 被预览器打开、或者临时手动生成过一份，都会让「最新」挑错。
MANUAL="$ROOT/docs/KesonMount使用说明书-$VERSION.pdf"
if [ ! -f "$MANUAL" ]; then
  MANUAL="$(ls -t "$ROOT"/docs/KesonMount使用说明书*.pdf 2>/dev/null | head -1 || true)"
fi
if [ -n "${MANUAL:-}" ] && [ -f "$MANUAL" ]; then
  cp "$MANUAL" "$APP/Contents/Resources/使用说明书.pdf"
  echo "  使用说明书：$(basename "$MANUAL")"
else
  echo "  ⚠️ 没找到使用说明书 PDF，先跑：/tmp/makepdf docs/说明书.html /tmp/manual.pdf && cp /tmp/manual.pdf docs/"
fi
printf 'APPL????' > "$APP/Contents/PkgInfo"
xattr -cr "$APP" 2>/dev/null || true

# 固定 DR：和 build.sh 保持一致。ad-hoc 默认会把 cdhash 写进 DR，每编一次就变，
# 钥匙串授权随之作废（装好后要重新输密码）。钉死 identifier 后长期有效。
SIGN_REQ='designated => identifier "com.keson.kesonmount"'

if ! codesign --force --deep --sign - -r="$SIGN_REQ" "$APP" >/dev/null 2>&1; then
  echo "⚠️ ad-hoc 签名失败，安装包可能无法在新机器上启动" >&2
fi
codesign --verify --deep --strict "$APP" && echo "  签名校验通过"

# ── DMG（拖拽安装）─────────────────────────────
echo "▶ 制作 DMG…"
STAGE="$WORK/dmg"
mkdir -p "$STAGE"
ditto --norsrc --noextattr "$APP" "$STAGE/$NAME.app"
ln -s /Applications "$STAGE/应用程序"
cp "$ROOT/Resources/安装说明.txt" "$STAGE/安装说明.txt"
if [ -n "${MANUAL:-}" ] && [ -f "$MANUAL" ]; then cp "$MANUAL" "$STAGE/使用说明书.pdf"; fi
DMG="$WORK/$NAME-$VERSION.dmg"
hdiutil create -quiet -volname "$NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
cp "$DMG" "$OUT/"

# ── PKG（双击安装到「应用程序」）──────────────
echo "▶ 制作 PKG…"
PKGROOT="$WORK/pkgroot"
mkdir -p "$PKGROOT/Applications"
ditto --norsrc --noextattr "$APP" "$PKGROOT/Applications/$NAME.app"
PKG="$WORK/$NAME-$VERSION.pkg"
pkgbuild --quiet --root "$PKGROOT" \
  --identifier "$BUNDLE_ID" \
  --version "$VERSION" \
  --install-location "/" \
  --ownership recommended \
  "$PKG"
cp "$PKG" "$OUT/"

echo
echo "✅ 安装包已生成："
for f in "$OUT/$NAME-$VERSION.dmg" "$OUT/$NAME-$VERSION.pkg"; do
  [ -f "$f" ] && printf "   %s  (%s)\n" "$(basename "$f")" "$(du -h "$f" | cut -f1 | tr -d ' ')"
done

# ── 同步一份到「文档库」，成品集中在一个文件夹里，Finder 里一眼能找到 ──
LIB="${KESONMOUNT_LIB:-${NETMOUNT_LIB:-$HOME/Documents/文档库/KesonMount}}"
mkdir -p "$LIB"
cp "$OUT/$NAME-$VERSION.dmg" "$OUT/$NAME-$VERSION.pkg" "$LIB/"
[ -f "$APP/Contents/Resources/使用说明书.pdf" ] && \
  cp "$APP/Contents/Resources/使用说明书.pdf" "$LIB/${NAME}使用说明书-$VERSION.pdf"
[ -f "$ROOT/README.md" ] && cp "$ROOT/README.md" "$LIB/产品说明.md"
ditto "$APP" "$LIB/$NAME.app"
echo "   已同步到文档库：$LIB"
