#!/bin/bash
# 回归测试：不启动 App、不碰钥匙串、不挂载磁盘；
# 只会真实 fork /bin 下的 echo / sleep / cat / sh / printf 验证子进程回收与管道不死锁。
# 用法： ./tests/run.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCH="$(uname -m)"
WORK="$(mktemp -d /tmp/kesonmount-tests.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

# 工程放在 SMB 卷上时，源码 mtime 抖动会让 swiftc 报
# 「input file … was modified during the build」。先拷到本机磁盘再编译。
ditto "$ROOT/Sources" "$WORK/Sources"
rm -f "$WORK/Sources/main.swift"          # 去掉 App 入口
cp "$ROOT/tests/main.swift" "$WORK/Sources/main.swift"   # 测试自己就是入口

echo "▶ 编译测试程序（${ARCH}）…"
swiftc -O -swift-version 5 -target "${ARCH}-apple-macos14.0" \
  -framework AppKit -framework WebKit -framework Foundation -framework Network \
  -framework UserNotifications -framework ServiceManagement \
  "$WORK"/Sources/*.swift -o "$WORK/kesonmount-tests"

echo "▶ 运行…"
"$WORK/kesonmount-tests"
