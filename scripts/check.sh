#!/bin/bash
# 提交前 / 打包前的全量静态检查。
# 用法： ./scripts/check.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
ARCH="$(uname -m)"

echo "▶ 1/5 Swift 类型检查"
SWIFT_OUT="$(swiftc -typecheck -swift-version 5 -target "${ARCH}-apple-macos14.0" \
  Sources/*.swift 2>&1 || true)"
if [ -n "$SWIFT_OUT" ]; then echo "$SWIFT_OUT" | head -30; fi
if echo "$SWIFT_OUT" | grep -q "error:"; then
  echo "❌ Swift 类型检查失败"
  exit 1
fi
echo "   OK（warning 不拦，但会打印出来）"

echo "▶ 2/5 界面 JavaScript 语法"
if command -v node >/dev/null 2>&1; then
  JS="$(mktemp /tmp/kesonmount-ui.XXXXXX.js)"
  trap 'rm -f "$JS"' EXIT
  python3 - "$JS" <<'PY'
import re, sys
s = open("Resources/ui.html", encoding="utf-8").read()
blocks = re.findall(r"<script[^>]*>([\s\S]*?)</script>", s)
open(sys.argv[1], "w", encoding="utf-8").write("\n".join(blocks))
print(f"   提取 {len(blocks)} 个 script 块")
PY
  node --check "$JS"
  echo "   OK"
else
  echo "   ⚠️ 没装 node，跳过（建议装上，界面 JS 语法错误会让整个界面起不来）"
fi

echo "▶ 3/5 说明书版本号一致性"
./scripts/sync-version.sh --check

echo "▶ 4/5 界面 action ↔ 原生桥对照"
python3 - <<'PY'
import re, sys
ui = open("Resources/ui.html", encoding="utf-8").read()
ac = open("Sources/AppController.swift", encoding="utf-8").read()
used = set(re.findall(r'''call\(\s*["']([A-Za-z][A-Za-z0-9]*)["']''', ui))
handled = set(re.findall(r'''case\s+"([A-Za-z][A-Za-z0-9]*)"\s*:''', ac))
missing = sorted(used - handled)
if missing:
    print(f"❌ 界面调用了但原生没处理的 action：{missing}")
    sys.exit(1)
print(f"   OK：界面 {len(used)} 个 action 全部有原生实现")
PY

echo "▶ 5/5 单元测试 + Shell 子进程回归"
./tests/run.sh

echo ""
echo "✅ 全部检查通过"
