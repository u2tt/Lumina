#!/usr/bin/env bash
# ============================================================
#  Lumina 视频壁纸 — 构建脚本
#  产物: dist/Lumina-<version>.zip（项目内不保留 .app）
#  用法: bash build/build.sh [--run] [--no-install]
# ============================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="Lumina"
BUNDLE_ID="com.chenxinyu.lumina"
VERSION="1.8.0"
BUILD_NUMBER="17"
MIN_MACOS="13.0"

DIST="$ROOT/dist"
BUILD="$ROOT/.build"
ZIP="$DIST/$APP_NAME-$VERSION.zip"
STAGE="$BUILD/stage"

# .app 只在临时目录里存在 —— macOS 26 的「App 库」按 LaunchServices 注册表收录
# app bundle，不管它在哪个目录；项目里只要出现过 .app，就会和 /Applications 里
# 那份形成重复图标（实测踩过两次）。
PACK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lumina-build.XXXXXX")"
trap 'rm -rf "$PACK_DIR"' EXIT
APP="$PACK_DIR/$APP_NAME.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

C_RESET=$'\033[0m'; C_BLUE=$'\033[1;34m'; C_GREEN=$'\033[1;32m'; C_RED=$'\033[1;31m'; C_DIM=$'\033[2m'
step() { printf "%s==>%s %s\n" "$C_BLUE" "$C_RESET" "$1"; }
ok()   { printf "%s  ✓%s %s\n" "$C_GREEN" "$C_RESET" "$1"; }
fail() { printf "%s  ✗%s %s\n" "$C_RED" "$C_RESET" "$1"; exit 1; }
dim()  { printf "%s     %s%s\n" "$C_DIM" "$1" "$C_RESET"; }

# ---------- 0. 环境检查 ----------
step "检查工具链"
command -v swiftc >/dev/null || fail "找不到 swiftc，请安装 Xcode Command Line Tools: xcode-select --install"
SDK="$(xcrun --show-sdk-path)"
[[ -d "$SDK" ]] || fail "找不到 macOS SDK"
ok "swiftc $(swiftc --version | head -1 | awk '{print $4}')"
dim "SDK: $SDK"

# ---------- 1. 清理 ----------
step "准备构建目录"
rm -rf "$STAGE"
mkdir -p "$STAGE" "$DIST"
ok "已清理 $STAGE"

# ---------- 2. 编译 Swift ----------
step "编译 Swift 源码"
SOURCES=()
while IFS= read -r f; do SOURCES+=("$f"); done < <(find "$ROOT/Sources/Lumina" -name '*.swift' | sort)
[[ ${#SOURCES[@]} -gt 0 ]] || fail "没有找到 Swift 源文件"
dim "${#SOURCES[@]} 个源文件"

BIN="$STAGE/$APP_NAME"
swiftc \
  -O -whole-module-optimization \
  -target arm64-apple-macos$MIN_MACOS \
  -sdk "$SDK" \
  -framework Cocoa -framework SwiftUI -framework AVFoundation \
  -framework QuartzCore -framework CoreGraphics -framework IOKit \
  "${SOURCES[@]}" \
  -o "$BIN" 2>&1 | sed 's/^/     /' || fail "Swift 编译失败"
ok "$(basename "$BIN") ($(du -h "$BIN" | cut -f1))"

# ---------- 3. 组装 app bundle ----------
step "组装 $APP_NAME.app（临时目录）"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"

if [[ -f "$ROOT/build/AppIcon.icns" ]]; then
  cp "$ROOT/build/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
  ok "已嵌入应用图标"
else
  dim "未找到 build/AppIcon.icns，跳过图标"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>       <string>Lumina 视频壁纸</string>
    <key>CFBundleExecutable</key>        <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>        <string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key>           <string>$BUILD_NUMBER</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleIconFile</key>          <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>    <string>$MIN_MACOS</string>
    <key>LSUIElement</key>               <true/>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
    <key>NSHumanReadableCopyright</key>  <string>Lumina Video Wallpaper</string>
</dict>
</plist>
PLIST

plutil -lint "$APP/Contents/Info.plist" >/dev/null || fail "Info.plist 格式错误"
ok "Info.plist 校验通过"

# ---------- 4. 签名 ----------
step "代码签名（ad-hoc）"
codesign --force --deep --sign - --timestamp=none "$APP" 2>&1 | sed 's/^/     /' || fail "签名失败"
codesign --verify --deep --strict "$APP" || fail "签名校验失败"
ok "ad-hoc 签名完成并通过校验"

# ---------- 5. 打包 zip ----------
step "打包发布 zip"
# 旧版本的 zip 一并清掉，避免 dist 里堆着分不清哪个是当前版本
rm -f "$DIST"/$APP_NAME-*.zip
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
ok "$(basename "$ZIP") ($(du -h "$ZIP" | cut -f1))"

# ---------- 6. 安装到 /Applications ----------
INSTALL=1
for a in "$@"; do [[ "$a" == "--no-install" ]] && INSTALL=0; done
INSTALLED="/Applications/$APP_NAME.app"

if [[ $INSTALL -eq 1 ]]; then
  step "安装到 /Applications"
  pkill -f "$INSTALLED/Contents/MacOS/$APP_NAME" 2>/dev/null && sleep 1 || true
  rm -rf "$INSTALLED"
  cp -R "$APP" "$INSTALLED"
  xattr -dr com.apple.quarantine "$INSTALLED" 2>/dev/null || true
  codesign --verify --deep --strict "$INSTALLED" || fail "安装后签名校验失败"
  ok "已安装 $INSTALLED"
fi

# 清理历史上残留在项目里的 .app（否则 macOS 26 App 库会出现重复图标）
for stray in "$ROOT"/*.app "$DIST"/*.app; do
  [[ -e "$stray" ]] || continue
  "$LSREGISTER" -u "$stray" 2>/dev/null || true
  rm -rf "$stray"
  dim "已清理项目内残留的 $(basename "$stray") 并注销 LaunchServices 注册"
done

# ---------- 7. 汇总 ----------
printf "\n%s构建完成%s\n" "$C_GREEN" "$C_RESET"
[[ $INSTALL -eq 1 ]] && printf "  已安装: %s\n" "$INSTALLED"
printf "  分发包: %s\n" "$ZIP"
printf "  日志  : ~/Library/Logs/Lumina.log\n"
printf "  %s（纯视频壁纸，不含实时渲染；项目内不保留 .app）%s\n\n" "$C_DIM" "$C_RESET"

if [[ "${1:-}" == "--run" ]]; then
  step "启动 $APP_NAME"
  open "$INSTALLED"
  ok "已启动，看菜单栏的 ✨ 图标"
fi
