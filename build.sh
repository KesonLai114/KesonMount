#!/bin/bash
# 构建「网盘管家」并安装到 /Applications
# 用法： ./build.sh            构建 + 安装 + 打开
#        ./build.sh --no-open  构建 + 安装，不打开
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAME="网盘管家"
ARCH="$(uname -m)"

# 源码放网络盘没问题，但 .app 必须构建在本机磁盘（SMB 上删不掉目录）
BUILD_ROOT="${TMPDIR:-/tmp}/netmount-build"
APP="$BUILD_ROOT/$NAME.app"
DEST="/Applications/$NAME.app"

echo "▶ 准备构建目录…"
rm -rf "$BUILD_ROOT"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# 源码先拷到本机磁盘再编译：网络卷的文件时间戳精度不够，
# 直接编译会报 "input file was modified during the build"
SRC="$BUILD_ROOT/src"
mkdir -p "$SRC"
ditto --norsrc --noextattr "$ROOT/Sources" "$SRC/Sources"
ditto --norsrc --noextattr "$ROOT/Resources" "$SRC/Resources"

echo "▶ 编译 Swift 源码…"
swiftc -O -swift-version 5 \
  -target "${ARCH}-apple-macos14.0" \
  -framework AppKit -framework WebKit -framework Foundation -framework Network \
  -framework UserNotifications -framework ServiceManagement \
  "$SRC"/Sources/*.swift \
  -o "$APP/Contents/MacOS/NetMount"

echo "▶ 打包资源…"
cp "$SRC/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$SRC/Resources/ui.html" "$APP/Contents/Resources/ui.html"
if [ -f "$SRC/Resources/AppIcon.icns" ]; then
  cp "$SRC/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi
# 内置使用说明书（菜单「帮助 → 使用说明书」读它）
# 按 Info.plist 的版本号精确取对应那份，别按 mtime 猜（预览器占用旧文件时会挑错）。
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$ROOT/Resources/Info.plist")"
MANUAL="$ROOT/docs/网盘管家使用说明书-$VERSION.pdf"
if [ ! -f "$MANUAL" ]; then
  MANUAL="$(ls -t "$ROOT"/docs/网盘管家使用说明书*.pdf 2>/dev/null | head -1 || true)"
fi
if [ -n "${MANUAL:-}" ] && [ -f "$MANUAL" ]; then
  cp "$MANUAL" "$APP/Contents/Resources/使用说明书.pdf"
  echo "  使用说明书：$(basename "$MANUAL")"
fi
printf 'APPL????' > "$APP/Contents/PkgInfo"

# 固定的 designated requirement。默认的 ad-hoc 签名会把二进制 cdhash 写进 DR，
# 每编译一次就变一次，钥匙串里「始终允许」的授权随之作废——于是每重新装一次
# 就要重新输一次密码解锁。钉死 identifier 后 DR 不再随代码变化，
# 用户在授权框上点过一次「始终允许」，以后长期有效。
# 代价：本机上 bundle id 相同的程序会被当成「同一个」——自用开发的取舍。
SIGN_REQ='designated => identifier "com.keson.netmount"'

if ! codesign --force --deep --sign - -r="$SIGN_REQ" "$APP" >/dev/null 2>&1; then
  echo "⚠️ ad-hoc 签名失败，App 可能无法正常启动" >&2
fi

echo "▶ 安装到 $DEST …"
pkill -x NetMount 2>/dev/null || true
# 删不掉就停下：旧 bundle 是 root 装的时，rm 会失败，继续 ditto 会把新二进制
# 合并进旧包——二进制换了、_CodeSignature 还是旧的，App 可能直接被 Gatekeeper 拒启
if [ -e "$DEST" ] && ! rm -rf "$DEST"; then
  echo "❌ 无法删除旧版本 ${DEST}（可能是用 PKG 以 root 安装的）。" >&2
  echo "   请先执行：sudo rm -rf \"${DEST}\" 后重试。" >&2
  exit 1
fi
ditto "$APP" "$DEST"

echo "✅ 完成：$DEST"

# 顺手把装好的 App 同步一份到「文档库」，成品集中在一个文件夹里
LIB="${NETMOUNT_LIB:-$HOME/Documents/文档库/网盘管家}"
if mkdir -p "$LIB" 2>/dev/null; then
  ditto "$DEST" "$LIB/$NAME.app"
  VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$DEST/Contents/Info.plist" 2>/dev/null || echo "")"
  [ -f "$DEST/Contents/Resources/使用说明书.pdf" ] && [ -n "$VERSION" ] && \
    cp "$DEST/Contents/Resources/使用说明书.pdf" "$LIB/${NAME}使用说明书-$VERSION.pdf"
  echo "   已同步到文档库：$LIB"
fi

if [ "${1:-}" != "--no-open" ]; then
  open "$DEST"
fi
