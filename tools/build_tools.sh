#!/usr/bin/env bash
# ============================================================
#  构建冒烟测试所需的诊断工具
#
#  这些是开发期用来验证行为的独立小程序（截图分析、黑帧检测、窗口层级查询），
#  不属于 app 本体。smoke_test.sh 会调用它们。
#
#  用法: bash tools/build_tools.sh
# ============================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/tools"
OUT="$ROOT/prototype"
mkdir -p "$OUT"

C_G=$'\033[1;32m'; C_R=$'\033[1;31m'; C_0=$'\033[0m'

# ⚠️ flashdetect 用了顶层代码 + await，文件名必须是 main.swift，
#    否则 swiftc 会报 "statements are not allowed at the top level"。
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

build_one() {
  local name="$1"
  local src="$SRC/$name.swift"
  [[ -f "$src" ]] || { printf "%s  ✗ 缺 %s%s\n" "$C_R" "$src" "$C_0"; return 1; }

  if [[ "$name" == "flashdetect" ]]; then
    cp "$src" "$TMP/main.swift"
    swiftc -O "$TMP/main.swift" -o "$OUT/$name" 2>&1 | grep -E "error" && return 1 || true
  else
    swiftc -O "$src" -o "$OUT/$name" 2>&1 | grep -E "error" && return 1 || true
  fi
  printf "%s  ✓ %s%s\n" "$C_G" "$name" "$C_0"
}

for t in diff center flashdetect allwin; do
  build_one "$t"
done

echo ""
echo "工具已构建到 $OUT"
echo "运行冒烟测试： bash build/smoke_test.sh"
