#!/usr/bin/env bash
# ============================================================
#  Lumina 视频壁纸 — 冒烟测试
#  自动生成测试视频，验证：窗口登记 / 单视频循环 / 多视频轮播 / 失效提示
#  用法: bash build/smoke_test.sh
# ============================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="/Applications/Lumina.app/Contents/MacOS/Lumina"
PROTO="$ROOT/prototype"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/lumina-smoke.XXXXXX")"
LOG="$HOME/Library/Logs/Lumina.log"

C_G=$'\033[1;32m'; C_R=$'\033[1;31m'; C_B=$'\033[1;34m'; C_0=$'\033[0m'; C_D=$'\033[2m'
pass=0; fail=0

cleanup() { pkill -9 -f "MacOS/Lumina" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT

ok()    { printf "  %s✓%s %s\n" "$C_G" "$C_0" "$1"; pass=$((pass+1)); }
bad()   { printf "  %s✗%s %s\n" "$C_R" "$C_0" "$1"; fail=$((fail+1)); }
head_() { printf "\n%s▶ %s%s\n" "$C_B" "$1" "$C_0"; }

kill_lumina() {
  pkill -f "MacOS/Lumina" 2>/dev/null
  local i=0
  while pgrep -f "MacOS/Lumina" >/dev/null 2>&1; do
    sleep 0.4; i=$((i+1))
    if (( i > 20 )); then pkill -9 -f "MacOS/Lumina" 2>/dev/null; sleep 0.6; break; fi
  done
  sleep 0.6
}

# 按窗口 ID 截图，避开前台窗口遮挡
shot() {
  local out="$1" num
  num="$(grep -o 'num=[0-9]*' "$LOG" 2>/dev/null | tail -1 | cut -d= -f2)"
  [[ -z "$num" ]] && return 1
  rm -f "$out"
  screencapture -x -o -l"$num" "$out" 2>/dev/null
  [[ -s "$out" ]]
}

start() {
  kill_lumina
  rm -f "$LOG"
  nohup "$BIN" "$@" >/dev/null 2>&1 &
  sleep 4.5
}

# ---------- 准备 ----------
echo "${C_B}════ Lumina 视频壁纸 冒烟测试 ════${C_0}"
[[ -x "$BIN" ]] || { echo "${C_R}找不到 $BIN，先跑 build/build.sh${C_0}"; exit 1; }
# 诊断工具缺失就现场构建（源码在 tools/，方便他人复现）
if [[ ! -x "$PROTO/diff" || ! -x "$PROTO/center" || ! -x "$PROTO/flashdetect" || ! -x "$PROTO/allwin" ]]; then
  echo "${C_D}诊断工具未构建，正在从 tools/ 编译…${C_0}"
  bash "$ROOT/tools/build_tools.sh" || { echo "${C_R}诊断工具构建失败${C_0}"; exit 1; }
fi
command -v ffmpeg >/dev/null 2>&1 || { echo "${C_R}需要 ffmpeg 生成测试视频${C_0}"; exit 1; }

ffmpeg -y -f lavfi -i "testsrc2=size=1280x720:rate=30:duration=8" \
  -c:v libx264 -pix_fmt yuv420p -preset veryfast -crf 25 "$WORK/01-bars.mp4" >/dev/null 2>&1
ffmpeg -y -f lavfi -i "color=c=0x0044FF:s=1280x720:r=15:d=6" \
  -c:v libx264 -pix_fmt yuv420p -preset veryfast "$WORK/02-blue.mp4" >/dev/null 2>&1
ffmpeg -y -f lavfi -i "color=c=0xFF7700:s=1280x720:r=15:d=6" \
  -c:v libx264 -pix_fmt yuv420p -preset veryfast "$WORK/03-orange.mp4" >/dev/null 2>&1
echo "${C_D}已生成 3 个测试视频${C_0}"

# ---------- 1. 单个视频循环 ----------
head_ "单个视频 → 循环播放"
start --reset >/dev/null 2>&1 || true
start --video "$WORK/01-bars.mp4"

grep -q "自检通过" "$LOG" && ok "壁纸窗口已被 WindowServer 接纳" || bad "窗口未被 WindowServer 接纳"
grep -q "循环播放" "$LOG" && ok "进入循环播放模式" || bad "未进入循环播放模式"

# ★ 层级必须在桌面图标之下，否则壁纸会把桌面图标整个盖住。
# 这是踩过的真实 bug：先前误信"低层级会被系统丢弃"（其实是被
# excludeDesktopElements 过滤了），选了高于图标的 -2147483600。
ICON_LEVEL=-2147483603
LVL="$(grep -o 'level=-*[0-9]*' "$LOG" | tail -1 | cut -d= -f2)"
if [[ -n "$LVL" ]] && (( LVL < ICON_LEVEL )); then
  ok "层级 $LVL 低于桌面图标，图标可见"
else
  bad "层级 ${LVL:-未知} 不低于桌面图标（$ICON_LEVEL），图标会被盖住"
fi
if [[ -n "$LVL" ]] && (( LVL < 0 )); then
  ok "层级低于普通窗口，不会遮挡应用"
else
  bad "层级 $LVL 可能遮挡应用窗口"
fi

# 播放速度必须真的达到设定值（时间轴推进速率是内部证据）
if grep -q "播放速度偏离" "$LOG"; then
  bad "播放速度偏离设定：$(grep -m1 '播放速度偏离' "$LOG" | sed 's/.*\[WARN\] //')"
else
  ok "播放速度与设定一致（无偏离告警）"
fi

# 高刷必须真正拿到：窗口默认 60Hz，4× 时 120 帧/秒会被不均匀丢掉导致发卡
if grep -q "高刷已生效" "$LOG"; then
  ok "已拿到高刷（$(grep -o 'display link 实测 [0-9.]* Hz' "$LOG" | tail -1)）"
else
  bad "未拿到高刷：$(grep -o 'display link 实测.*' "$LOG" | tail -1)"
fi

if shot "$WORK/a1.png"; then
  sleep 2.5
  shot "$WORK/a2.png"
  d="$("$PROTO/diff" "$WORK/a1.png" "$WORK/a2.png" 2>/dev/null | sed -n 's/.*占比 \([0-9.]*\)%.*/\1/p')"
  if [[ -n "$d" ]] && awk -v x="${d:-0}" 'BEGIN{exit !(x>0.5)}'; then
    ok "画面在动（2.5 秒间 ${d}% 像素变化）"
  else
    bad "画面静止（变化 ${d:-0}%）"
  fi
else
  bad "截不到壁纸窗口"
fi

# ---------- 1b. 运行时切换倍速 ----------
# 曾经 3/4/5× 速度完全一样：签名里只放了"是否需要烘焙"的布尔量，
# 3×→5× 签名不变所以不重建，一直按第一次的 3× 播。
head_ "运行时切换倍速 → 每档都要重建时间轴"
kill_lumina
rm -f "$LOG"
LUMINA_SELFTEST="3,5,4" nohup "$BIN" --video "$WORK/01-bars.mp4" --speed 3 >/dev/null 2>&1 &
sleep 24

if [[ "$(grep -c '已烘焙进时间轴' "$LOG")" -ge 3 ]]; then
  ok "3 个倍速各自重建了时间轴"
  # 压缩结果必须互不相同
  N="$(grep -o '压缩为 [0-9.]*s' "$LOG" | sort -u | wc -l | tr -d ' ')"
  if [[ "$N" -ge 3 ]]; then ok "各倍速的压缩时长互不相同"; else bad "压缩时长重复（只有 $N 种），说明没真正重建"; fi
else
  bad "倍速切换未触发重建（仅 $(grep -c '已烘焙进时间轴' "$LOG") 次烘焙）"
fi

if grep -q "倍速区间与播放器状态不一致" "$LOG"; then
  bad "检测到倍速与播放器状态不一致"
else
  ok "倍速与播放器状态一致"
fi

# 每次切换都必须保持进度（曾经切到 ≤2× 时会跳回开头：
# 那时用 item.duration 判定，而 AVPlayerItem(url:) 刚建时 duration 还是 invalid）
SWITCHES="$(grep -c '自测：切到' "$LOG")"
KEEPS="$(grep -c '保持播放进度' "$LOG")"
if [[ "$SWITCHES" -gt 0 && "$KEEPS" -ge "$SWITCHES" ]]; then
  ok "每次切换都保持了进度（$KEEPS/$SWITCHES）"
else
  bad "有切换没保持进度（$KEEPS/$SWITCHES）—— 可能又跳回开头了"
fi

# 切换时不能出现黑帧。双缓冲就是为了消除 replaceCurrentItem 造成的闪黑。
WID="$(grep -o 'num=[0-9]*' "$LOG" | tail -1 | cut -d= -f2)"
if [[ -n "$WID" ]]; then
  FLASH="$("$PROTO/flashdetect" "$WID" 12 2>/dev/null | grep -o '接近全黑：[0-9]* 次' | grep -o '[0-9]*')"
  if [[ "${FLASH:-1}" == "0" ]]; then
    ok "切换期间无黑帧（12 秒采样）"
  else
    bad "切换期间出现黑帧（$FLASH 次）"
  fi
else
  bad "拿不到窗口 ID，无法检查黑帧"
fi

# 改倍速不能从头开始：必须有"保持播放进度"且进度递增
KEEP="$(grep -c '保持播放进度' "$LOG")"
if [[ "$KEEP" -ge 2 ]]; then
  ok "改倍速保留了播放进度（$KEEP 次）"
  # ⚠️ 不能断言"进度递增"：短测试视频切到高倍速后时间轴变短，
  #    换算回来的源位置可能比上次小，那是正常的。
  #    正确的判据是「切换前的源进度」必须明显大于 0 —— 从头开始的话它会是 0。
  ALL="$(grep -o '进度 [0-9.]*s' "$LOG" | grep -o '[0-9.]*')"
  POSITIVE=0
  for v in $ALL; do awk -v x="$v" 'BEGIN{exit !(x > 1.0)}' && POSITIVE=$((POSITIVE+1)); done
  if [[ "$POSITIVE" -ge 2 ]]; then
    ok "切换前都已有实际进度（$POSITIVE 次），未从头开始"
  else
    bad "切换前进度接近 0，说明仍在从头播放（读到：$ALL）"
  fi
else
  bad "改倍速没有保留进度（仅 $KEEP 次）"
fi

# ---------- 2b. 文件夹轮播 + 随机播放 ----------
head_ "多视频轮播 → 播完自动切下一个"
# 造 4 个各 2 秒的纯色视频
for spec in "r:0xFF0000" "g:0x00FF00" "b:0x0000FF" "y:0xFFFF00"; do
  nm="${spec%%:*}"; col="${spec##*:}"
  ffmpeg -y -f lavfi -i "color=c=$col:s=320x240:r=15:d=2" \
    -c:v libx264 -pix_fmt yuv420p -preset ultrafast "$WORK/rot-$nm.mp4" >/dev/null 2>&1
done

kill_lumina
rm -f "$LOG"
nohup "$BIN" --video "$WORK/rot-b.mp4" "$WORK/rot-g.mp4" "$WORK/rot-r.mp4" "$WORK/rot-y.mp4" \
  >/dev/null 2>&1 &
sleep 11

if grep -q "播放列表共 4 个" "$LOG"; then
  ok "识别为 4 个视频的播放列表"
else
  bad "未建立播放列表（$(grep -c '轮播切换' "$LOG") 次切换）"
fi

SW="$(grep -c '轮播切换（播放结束）' "$LOG")"
if [[ "$SW" -ge 3 ]]; then
  ok "播完自动切换正常（$SW 次）"
else
  bad "自动切换次数不足（$SW 次）"
fi

# 顺序模式：应严格按 01→02→03 的文件名顺序
if grep -q "按文件名顺序" "$LOG"; then
  ok "默认按文件名顺序"
else
  bad "未按文件名顺序"
fi

# 轮播切换期间不能黑屏（双缓冲的意义）
WID="$(grep -o 'num=[0-9]*' "$LOG" | tail -1 | cut -d= -f2)"
if [[ -n "$WID" ]]; then
  FL="$("$PROTO/flashdetect" "$WID" 9 2>/dev/null | grep -o '接近全黑：[0-9]* 次' | grep -o '[0-9]*')"
  if [[ "${FL:-1}" == "0" ]]; then
    ok "轮播切换期间无黑帧"
  else
    bad "轮播期间出现黑帧（$FL 次）"
  fi
fi

# ★ 轮播中途改倍速，不能把视频切走
# 踩过的 bug：判断"是否同一个视频"时拿的是列表第一个（usable.first），
# 轮播到第 3 个时改倍速会被误判成"换了视频" → 重建时从 playlist[0] 开始播。
head_ "轮播中途改倍速 → 视频不应被切走"
kill_lumina
rm -f "$LOG"
LUMINA_SELFTEST="1,2" LUMINA_SELFTEST_GAP=6 \
  nohup "$BIN" --video "$WORK/rot-b.mp4" "$WORK/rot-g.mp4" "$WORK/rot-r.mp4" "$WORK/rot-y.mp4" \
  >/dev/null 2>&1 &
sleep 15

# 找出"自测：切到"那行之前正在播的视频，和之后实际播放的视频
# 提取"当前视频 xxx.mp4"里的文件名。⚠️ 不能用 [^,]* —— 中文逗号是全角的，
# 那样会把后面的"，进度 1.5s）"一起吞进来，导致比较必然失败。
BEFORE="$(grep '自测：切到' "$LOG" | head -1 | grep -oE '当前视频 [^）]*' | sed 's/当前视频 //' | sed 's/，.*//' | tr -d ' ')"
AFTER="$(grep '循环播放' "$LOG" | awk -v b="$BEFORE" 'index($0,b){found=NR} END{print found}' )"
if [[ -n "$BEFORE" ]]; then
  # 切换后第一条"循环播放"里的文件名应与切换前一致
  POST="$(awk -v b="$BEFORE" '/自测：切到/{seen=1} seen && /循环播放/{print; exit}' "$LOG")"
  if [[ -n "$POST" ]] && echo "$POST" | grep -q "$BEFORE"; then
    ok "改倍速后仍是同一个视频（$BEFORE）"
  else
    bad "改倍速把视频切走了：切换前 $BEFORE，切换后 $(echo "$POST" | sed -n 's/.*播放 \([^ ]*\).*/\1/p')"
  fi
else
  bad "测试期间未触发倍速切换（无法验证）"
fi
_="$AFTER"

# ★「下一幅」按钮：连续点应按顺序逐个前进并循环
head_ "「下一幅」按钮 → 逐个前进并循环"
kill_lumina
rm -f "$LOG"
# 用 20 秒长视频，确保不会自动播完，切换只可能来自"下一幅"
for spec in "n1:0xFF0000" "n2:0x00FF00" "n3:0x0000FF"; do
  nm="${spec%%:*}"; col="${spec##*:}"
  ffmpeg -y -f lavfi -i "color=c=$col:s=320x240:r=15:d=20" \
    -c:v libx264 -pix_fmt yuv420p -preset ultrafast "$WORK/$nm.mp4" >/dev/null 2>&1
done
LUMINA_NEXT_TEST="3,2" \
  nohup "$BIN" --video "$WORK/n1.mp4" "$WORK/n2.mp4" "$WORK/n3.mp4" >/dev/null 2>&1 &
sleep 14

NEXT="$(grep -c '手动切下一幅' "$LOG")"
if [[ "$NEXT" -ge 3 ]]; then
  ok "「下一幅」触发正常（$NEXT 次）"
else
  bad "「下一幅」触发次数不足（$NEXT 次）"
fi

# 应严格逐个前进：n1→n2→n3→n1
SEQ="$(grep -o '→ n[0-9]\.mp4' "$LOG" | tr '\n' ' ')"
EXPECT="→ n2.mp4 → n3.mp4 → n1.mp4 "
if [[ "$SEQ" == "$EXPECT" ]]; then
  ok "逐个前进且回到开头（$SEQ）"
else
  bad "前进顺序不对：期望「$EXPECT」，实际「$SEQ」"
fi

# 手动切换不能黑屏
WID="$(grep -o 'num=[0-9]*' "$LOG" | tail -1 | cut -d= -f2)"
if [[ -n "$WID" ]]; then
  FL="$("$PROTO/flashdetect" "$WID" 8 2>/dev/null | grep -o '接近全黑：[0-9]* 次' | grep -o '[0-9]*')"
  if [[ "${FL:-1}" == "0" ]]; then
    ok "「下一幅」切换期间无黑帧"
  else
    bad "「下一幅」切换期间出现黑帧（$FL 次）"
  fi
fi

# 随机播放：顺序应被打乱，且一轮内不重复
head_ "随机播放 → 顺序打乱且一轮内不重复"
kill_lumina
rm -f "$LOG"
nohup "$BIN" --video "$WORK/rot-b.mp4" "$WORK/rot-g.mp4" "$WORK/rot-r.mp4" "$WORK/rot-y.mp4" --shuffle \
  >/dev/null 2>&1 &
sleep 11

if grep -q "随机顺序" "$LOG"; then
  ok "已启用随机顺序"
else
  bad "未启用随机顺序"
fi
# 每轮 4 个应各不相同
SEQ="$(grep -o '→ rot-[bgry]\.mp4' "$LOG" | head -4 | tr '\n' ' ')"
UNIQ="$(echo $SEQ | tr ' ' '\n' | grep -c .)"
DISTINCT="$(echo $SEQ | tr ' ' '\n' | sort -u | grep -c .)"
if [[ "$DISTINCT" -ge 4 ]]; then
  ok "一轮内 4 个互不重复（$SEQ）"
else
  bad "一轮内有重复（$SEQ）"
fi

# ---------- 2c. 清空视频 → 必须销毁窗口露出系统壁纸 ----------
# 曾经的 bug：清空后窗口还在（黑底）盖住系统壁纸，用户看到"清空后黑屏"。
head_ "清空视频 → 销毁窗口，显示系统壁纸"
kill_lumina
rm -f "$LOG"
WORKNAME="$(basename "$WORK")"
LUMINA_CLEARTEST=6 LUMINA_CLEARTEST_RESTORE="$WORK/01-bars.mp4" \
  nohup "$BIN" --video "$WORK/01-bars.mp4" --speed 1 >/dev/null 2>&1 &
sleep 4
N1="$(lsof -c Lumina 2>/dev/null | grep -c "$WORKNAME" || true)"
sleep 4
# 清空后：不该再有壁纸窗口（层级 -2147483610）
if "$PROTO/allwin" 2>/dev/null | grep -q "layer=-2147483610"; then
  bad "清空后壁纸窗口仍在（会黑屏盖住系统壁纸）"
else
  ok "清空后壁纸窗口已销毁（系统壁纸可见）"
fi
if grep -q "视频已清空 → 销毁壁纸窗口" "$LOG"; then
  ok "日志确认执行了销毁"
else
  bad "未见销毁日志"
fi
sleep 8
if "$PROTO/allwin" 2>/dev/null | grep -q "layer=-2147483610"; then
  ok "恢复视频后窗口重建"
else
  bad "恢复视频后窗口未重建"
fi
# 动作各应只发生一次（通知重入会让它翻倍，导致白重建两次）
DESTROY="$(grep -c '视频已清空 → 销毁' "$LOG")"
CREATE="$(grep -c '已有视频 → 创建' "$LOG")"
if [[ "$DESTROY" -le 1 && "$CREATE" -le 1 ]]; then
  ok "清空/创建各只执行一次（无通知重入）"
else
  bad "动作重复执行（销毁 $DESTROY 次、创建 $CREATE 次）"
fi
_="$N1"

# ---------- 3. 文件失效 ----------
head_ "视频文件被移走 → 屏上提示而非黑屏"
mkdir -p "$WORK/hidden"
mv "$WORK"/*.mp4 "$WORK/hidden"/ 2>/dev/null

kill_lumina
rm -f "$LOG"
nohup "$BIN" >/dev/null 2>&1 &     # 沿用上次设置，但文件已不存在
sleep 4.5

grep -q "无可用视频" "$LOG" && ok "识别出文件失效" || bad "未识别文件失效"
grep -q "已配置但文件不存在" "$LOG" && ok "区分了「未配置」与「文件失效」" || bad "未区分失效场景"

# ---------- 汇总 ----------
echo ""
echo "${C_B}════ 结果 ════${C_0}"
echo "通过 $pass 项，失败 $fail 项"
(( fail > 0 )) && exit 1
echo "${C_G}全部通过${C_0}"
