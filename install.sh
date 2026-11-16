#!/bin/bash
# 生成并安装「划词查询.app」
#
#   ./install.sh                装进「应用程序」并打开
#   ./install.sh --to <目录>    装到别的目录，不打开
#   ./install.sh --from <App>   指定运行时，不在本机查找、不下载
#
# 运行时是 Hammerspoon 的官方发布版：复制一份，换上名字、图标和自己的标识，去掉用不到的系统集成
# （服务菜单、「打开方式」、默认浏览器、快捷指令、自动更新），重新签名。代码仍从这个目录加载。
set -euo pipefail

NAME="划词查询"
BUNDLE_ID="io.github.liuzemei.llm-lookup"
RUNTIME_ID="org.hammerspoon.Hammerspoon"
RUNTIME_TEAM="VQCYSNZB89"
REPO="$(cd "$(dirname "$0")" && pwd -P)"
DEST="/Applications"
FROM=""
OPEN=1

while [ $# -gt 0 ]; do
  case "$1" in
    --to) DEST="${2:?}"; OPEN=0; shift 2 ;;
    --from) FROM="${2:?}"; shift 2 ;;
    -h|--help) sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "不认识的参数：$1" >&2; exit 2 ;;
  esac
done

step() { printf '\033[1m==>\033[0m %s\n' "$*" >&2; }
die() { printf '\033[31m%s\033[0m\n' "$*" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# 只用官方签名完好、没被改过的运行时打包（不加 --strict：在访达里换过图标的也算）
genuine() {
  [ -d "$1" ] || return 1
  [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist" 2>/dev/null)" = "$RUNTIME_ID" ] || return 1
  codesign --verify --deep "$1" 2>/dev/null || return 1
  codesign -dv "$1" 2>&1 | grep -q "^TeamIdentifier=$RUNTIME_TEAM\$"
}

# 先找本机已有的（改过名的也算），没有再从 GitHub 下载最新版
find_runtime() {
  if [ -n "$FROM" ]; then
    genuine "$FROM" || die "$FROM 不是官方签名的运行时"
    echo "$FROM"
    return
  fi
  local p tag releases=https://github.com/Hammerspoon/hammerspoon/releases
  while IFS= read -r p; do
    if genuine "$p"; then echo "$p"; return; fi
  done < <(printf '%s\n' /Applications/Hammerspoon.app "$HOME/Applications/Hammerspoon.app"
           mdfind "kMDItemCFBundleIdentifier == '$RUNTIME_ID'" 2>/dev/null || true)
  # latest 会跳转到最新版本的 tag 页面；不走 API，免得匿名请求被限流
  tag="$(curl -fsSI -o /dev/null -w '%{redirect_url}' "$releases/latest" | sed 's|.*/tag/||')" || true
  [ -n "$tag" ] || die "取不到最新版本。可以手动下载 $releases 里的 zip，解压后用 --from 指定"
  step "下载运行时 ${tag}…"
  curl -fL --progress-bar -o "$TMP/runtime.zip" "$releases/download/$tag/Hammerspoon-$tag.zip" \
    || die "下载失败。可以手动下载 $releases 里的 zip，解压后用 --from 指定"
  ditto -x -k "$TMP/runtime.zip" "$TMP/runtime"
  p="$(find "$TMP/runtime" -maxdepth 2 -name '*.app' | head -1)"
  genuine "$p" || die "下载的运行时没通过签名校验"
  echo "$p"
}

SRC="$(find_runtime)"
step "用 $SRC 生成 $NAME.app"
APP="$TMP/$NAME.app"
ditto "$SRC" "$APP"
# 访达自定义图标留下的文件和扩展属性，签名时不允许出现
rm -f "$APP/Icon"$'\r'
xattr -cr "$APP"

PLIST="$APP/Contents/Info.plist"
plist_del() { /usr/libexec/PlistBuddy -c "Delete :$1" "$PLIST" 2>/dev/null || true; }
plist_set() { plist_del "$1"; /usr/libexec/PlistBuddy -c "Add :$1 $2 $3" "$PLIST"; }

# 菜单栏、活动监视器、辅助功能列表、登录项里显示的名字；标识换成自己的，偏好设置和权限都和原版分开
plist_set CFBundleName string "$NAME"
plist_set CFBundleDisplayName string "$NAME"
plist_set CFBundleIdentifier string "$BUNDLE_ID"
plist_set SUEnableAutomaticChecks bool false
# 服务菜单、「打开方式」、默认浏览器、接力、快捷指令、脚本词典、自动更新，以及用不到的权限说明
for k in NSServices CFBundleURLTypes CFBundleDocumentTypes UTExportedTypeDeclarations NSUserActivityTypes \
  INIntentsSupported OSAScriptingDefinition NSAppleScriptEnabled SUFeedURL SUPublicEDKey SUPublicDSAKeyFile \
  NSAppleEventsUsageDescription NSCameraUsageDescription NSMicrophoneUsageDescription NSLocationAlwaysUsageDescription; do
  plist_del "$k"
done

# 图标：删掉 CFBundleIconName，系统就不用 Assets.car 里原来的，改用 AppIcon.icns
plist_del CFBundleIconName
ICONSET="$TMP/AppIcon.iconset"
mkdir "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z "$s" "$s" "$REPO/llm_lookup/appicon.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) "$REPO/llm_lookup/appicon.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# 改了 Info.plist 原签名就失效了，重新做本机签名
codesign --force --deep --sign - "$APP" 2>/dev/null
codesign --verify --deep --strict "$APP"

# 入口放在 Application Support（历史记录也在这）：运行时会在入口旁边建 Spoons 目录，不弄乱仓库
ENTRY="$HOME/Library/Application Support/llm-lookup/init.lua"
mkdir -p "$(dirname "$ENTRY")"
cat > "$ENTRY" <<EOF
-- install.sh 生成：「$NAME.app」的入口，代码从仓库载入
package.path = [==[$REPO/?.lua;$REPO/?/init.lua;]==] .. package.path
-- 存成全局变量，避免里面的热键 / 事件监听被 GC
llmLookup = require("llm_lookup").start()
EOF

# 运行时自己的菜单栏图标、Dock 图标、控制台和自动更新都关掉
defaults write "$BUNDLE_ID" MJConfigFile "$ENTRY"
defaults write "$BUNDLE_ID" MJShowMenuIconKey -bool false
defaults write "$BUNDLE_ID" MJShowDockIconKey -bool false
defaults write "$BUNDLE_ID" HSOpenConsoleOnDockClickKey -bool false
defaults write "$BUNDLE_ID" SUEnableAutomaticChecks -bool false

TARGET="$DEST/$NAME.app"
step "安装到 $TARGET"
if [ -e "$TARGET" ]; then
  [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$TARGET/Contents/Info.plist" 2>/dev/null)" = "$BUNDLE_ID" ] \
    || die "$TARGET 已经存在，而且不是这个脚本装的，先把它挪走"
  # 旧版正在运行的话先退出
  if pkill -f "$TARGET/Contents/MacOS/"; then
    for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -f "$TARGET/Contents/MacOS/" >/dev/null || break; sleep 0.5; done
  fi
  rm -rf "$TARGET"
fi
mkdir -p "$DEST"
ditto "$APP" "$TARGET"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$TARGET"

if grep -qs "llm_lookup" "$HOME/.hammerspoon/init.lua"; then
  printf '\n\033[33m~/.hammerspoon/init.lua 里还在加载旧的装法，两边同时运行会重复弹窗。确认新版能用后，删掉那里 require("llm_lookup") 那一行，或者直接退出、删除旧的 App。\033[0m\n' >&2
fi

[ "$OPEN" = 1 ] && open "$TARGET"
cat >&2 <<EOF

装好了。还差一步：在「系统设置 › 隐私与安全性 › 辅助功能」里打开「${NAME}」（设置面板顶部有入口）。
代码从 $REPO 加载，不要移动或删除这个目录；挪了位置就重新运行一次 ./install.sh。
EOF
