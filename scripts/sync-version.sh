#!/bin/bash
# 把 Info.plist 的版本号同步进说明书 HTML（封面、每页页脚、示例、安装包文件名）。
# 用法：
#   ./scripts/sync-version.sh            # 写入
#   ./scripts/sync-version.sh --check    # 只检查，不同步（供 CI / check.sh 调用）
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)"
BUILD="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Resources/Info.plist)"
MODE="${1:-}"

python3 - "$VERSION" "$BUILD" "$MODE" <<'PY'
import re
import sys
from pathlib import Path

version, build, mode = sys.argv[1], sys.argv[2], sys.argv[3]
p = Path("docs/说明书.html")
s = p.read_text(encoding="utf-8")

# 说明书里同时出现「产品版本 1.5.0」和「SMB 协议版本 3.1.1 / 3.0 / 2.1」。
# 只认与当前产品同主版本（1.x）的三段式版本号，避免把协议版本也改掉。
# 主版本升到 2.x 时 major 会自动跟着 Info.plist 变，不需要改这里。
major = re.escape(version.split(".")[0])
version_pattern = re.compile(rf"(?<![\d.]){major}\.\d+\.\d+(?![\d.])")
found = sorted(set(version_pattern.findall(s)))
stale = [v for v in found if v != version]

if mode == "--check":
    if stale:
        print(f"❌ 说明书里还残留旧版本号 {stale}，当前 Info.plist 是 {version}")
        print("   跑 ./scripts/sync-version.sh 同步，再重新生成 PDF。")
        sys.exit(1)
    if f"构建 {build}" not in s:
        print(f"❌ 说明书里没找到「构建 {build}」，版本号示例没跟上")
        sys.exit(1)
    print(f"✅ 说明书版本一致：{version}（构建 {build}）")
    sys.exit(0)

s = version_pattern.sub(version, s)
s = re.sub(r"构建 \d+", f"构建 {build}", s)
p.write_text(s, encoding="utf-8")
print(f"✅ 已把说明书版本同步为 {version}（构建 {build}）：替换了 {len(stale)} 个旧版本号 {stale}")
print("   记得重新生成 PDF：/tmp/makepdf docs/说明书.html /tmp/manual.pdf")
PY
