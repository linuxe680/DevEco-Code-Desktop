#!/bin/zsh
set -euo pipefail

# 唯一的本地安装入口：构建 → 原子覆盖 /Applications/DevEco Code Desktop.app。
#
# 关键约定（避免“App 里出现很多个 DevEco Code Desktop”）：
#   1. 目标路径永远是同一个 `/Applications/DevEco Code Desktop.app`，不带
#      架构后缀、不带时间戳，覆盖安装而不是并排安装。
#   2. 新包先落到同目录的临时目录并校验签名，再用两次 rename 原子替换；
#      旧包直接删除，不留 `.backup-*` 副本。
#   3. 每次安装顺带清理历史遗留的备份包与仓库内构建产物。
#
# Usage: ./Scripts/install.sh [arm64|x86_64] [min-macos]

ROOT="${0:A:h:h}"
ARCH="${1:-$(uname -m)}"
MIN_MACOS="${2:-12.0}"
DEST_DIR="/Applications"
DEST_APP="$DEST_DIR/DevEco Code Desktop.app"
BUNDLE_ID="com.local.deveco-codesktop"
SUPPORT="$HOME/Library/Application Support/DevEcoCodeDesktop"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"

say() { printf '%s\n' "$*"; }

unregister() {
    [ -x "$LSREGISTER" ] || return 0
    "$LSREGISTER" -u "$1" >/dev/null 2>&1 || true
}

# 列出 LaunchServices 中登记的所有同 bundle id 应用路径。构建产物、临时目录
# 和已卸载 DMG 都会被登记成“第二份 App”，仅删除文件并不会让启动台消失。
registered_app_paths() {
    [ -x "$LSREGISTER" ] || return 0
    local dump
    dump="$("$LSREGISTER" -dump 2>/dev/null)" || return 0
    printf '%s\n' "$dump" | awk -v id="$BUNDLE_ID" '
        /^path:[[:space:]]/ {
            candidate = $0
            sub(/^path:[[:space:]]+/, "", candidate)
            sub(/ \(0x[0-9a-fA-F]+\)$/, "", candidate)
            next
        }
        /^identifier:[[:space:]]/ {
            ident = $2
            if (ident == id && candidate != "") print candidate
            candidate = ""
        }
    ' | sort -u
}

prune_registered_copies() {
    local keep="$1" app_path
    while IFS= read -r app_path; do
        [ -n "$app_path" ] || continue
        [ "$app_path" = "$keep" ] && continue
        say "    unregister stale copy ${app_path}"
        unregister "$app_path"
    done < <(registered_app_paths)
}

# --- 0. 停止运行中的实例（否则替换后仍跑着旧二进制）-------------------------
# 必须按进程名精确匹配：`-f` 会连编译命令行里含 DevEcoCodeDesktop 路径的
# swift-frontend 一起杀掉，导致正在进行的构建被中断。
if pgrep -x 'DevEcoCodeDesktop' >/dev/null 2>&1; then
    say "==> 停止运行中的 DevEco Code Desktop"
    pkill -x 'DevEcoCodeDesktop' 2>/dev/null || true
    for _ in {1..40}; do
        pgrep -x 'DevEcoCodeDesktop' >/dev/null 2>&1 || break
        sleep 0.1
    done
    pkill -9 -x 'DevEcoCodeDesktop' 2>/dev/null || true
fi

# 强制结束 App 时 applicationWillTerminate 不会执行，`deveco serve` 会变成
# 孤儿进程继续占着旧端口，下次启动就只能换端口——端口号越用越大，还会出现
# 多个服务同时在跑。这里按数据目录精确识别并清理本 App 启动的服务。
reap_orphan_servers() {
    local pid env_line
    for pid in $(pgrep -f 'deveco serve' 2>/dev/null); do
        env_line="$(ps eww -p "$pid" -o command= 2>/dev/null)" || continue
        case "$env_line" in
            *"XDG_DATA_HOME=$SUPPORT/deveco-data"*)
                say "    stop orphaned deveco serve (pid $pid)"
                kill -TERM "$pid" 2>/dev/null || true
                ;;
        esac
    done
    sleep 0.5
    for pid in $(pgrep -f 'deveco serve' 2>/dev/null); do
        env_line="$(ps eww -p "$pid" -o command= 2>/dev/null)" || continue
        case "$env_line" in
            *"XDG_DATA_HOME=$SUPPORT/deveco-data"*)
                kill -KILL "$pid" 2>/dev/null || true
                ;;
        esac
    done
}

say "==> 清理遗留的 deveco 服务进程"
reap_orphan_servers

# --- 1. 清理历史遗留的多份 app ---------------------------------------------
say "==> 清理历史备份与构建产物"
cleanup_glob() {
    local pattern="$1"
    local match
    for match in ${~pattern}(N); do
        say "    remove ${match}"
        unregister "$match"
        rm -rf "$match"
    done
}

# 旧安装脚本/手工安装留下的 `DevEco Code Desktop.backup-YYYYMMDD-HHMMSS.app`
cleanup_glob "$DEST_DIR/DevEco Code Desktop.backup-*.app"
# 应用自身曾把旧版本拷到 AppBackups 目录
cleanup_glob "$SUPPORT/AppBackups/*.app"
# 早期脚本把 .app 直接建在仓库根目录，会被 Spotlight 当成第二份应用
cleanup_glob "$ROOT/DevEco Code Desktop*.app"
# 构建产物、临时安装目录、已卸载 DMG 的 LaunchServices 登记
prune_registered_copies "$DEST_APP"

# --- 2. 构建 ---------------------------------------------------------------
"$ROOT/Scripts/build-app.sh" "$ARCH" "$MIN_MACOS"
SRC_APP="$ROOT/build/DevEco Code Desktop ($ARCH).app"
[ -d "$SRC_APP" ] || { say "构建产物缺失：$SRC_APP"; exit 1; }

# --- 3. 原子覆盖安装 --------------------------------------------------------
mkdir -p "$DEST_DIR"
STAGE="$(mktemp -d "$DEST_DIR/.deveco-install.XXXXXX")"
STALE="$DEST_DIR/.deveco-stale.$$"
cleanup_stage() { rm -rf "$STAGE" "$STALE"; }
trap cleanup_stage EXIT

say "==> 暂存新版本"
ditto "$SRC_APP" "$STAGE/DevEco Code Desktop.app"
codesign --verify --deep --strict "$STAGE/DevEco Code Desktop.app"

if [ -e "$DEST_APP" ]; then
    say "==> 替换 $DEST_APP"
    unregister "$DEST_APP"
    mv "$DEST_APP" "$STALE"
    mv "$STAGE/DevEco Code Desktop.app" "$DEST_APP"
    rm -rf "$STALE"
else
    say "==> 安装到 $DEST_APP"
    mv "$STAGE/DevEco Code Desktop.app" "$DEST_APP"
fi

# 安装期间再次登记正式副本后，构建产物不应重新出现。最后统一核对。
touch "$DEST_APP"
[ -x "$LSREGISTER" ] && "$LSREGISTER" -f "$DEST_APP" >/dev/null 2>&1 || true
prune_registered_copies "$DEST_APP"
# 构建中间产物不留在可被聚焦/启动台扫到的位置；需要时重新跑构建即可。
cleanup_glob "$ROOT/build/DevEco Code Desktop*.app"

# --- 4. 结果核对 ------------------------------------------------------------
typeset -a LEFT
LEFT=("$DEST_DIR"/DevEco\ Code\ Desktop*.app(N))
COUNT=${#LEFT}
typeset -a REGISTERED
REGISTERED=("${(@f)$(registered_app_paths)}")
REGISTERED=("${REGISTERED[@]:#}")
REG_COUNT=${#REGISTERED}
if [ "$REG_COUNT" -eq 0 ]; then
    say "警告：无法从 LaunchServices 读到安装登记（lsregister 不可用？）"
    exit 1
fi
say ""
say "已安装：$DEST_APP"
say "版本：$(plutil -extract CFBundleShortVersionString raw "$DEST_APP/Contents/Info.plist") (build $(plutil -extract CFBundleVersion raw "$DEST_APP/Contents/Info.plist"))"
say "构建时间：$(plutil -extract DevEcoBuildTime raw -o - "$DEST_APP/Contents/Info.plist" 2>/dev/null || echo unknown)"
say "Git 提交：$(plutil -extract DevEcoGitCommit raw -o - "$DEST_APP/Contents/Info.plist" 2>/dev/null || echo unknown)"
say "架构：$ARCH"
say "/Applications 内匹配项：$COUNT"
[ "$COUNT" -eq 1 ] || { say "警告：/Applications 里仍有多个 DevEco Code Desktop："; printf '    %s\n' "${LEFT[@]}"; exit 1; }
say "LaunchServices 登记项：$REG_COUNT"
if [ "$REG_COUNT" -ne 1 ] || [ "${REGISTERED[1]:-}" != "$DEST_APP" ]; then
    say "警告：LaunchServices 里仍有其他 DevEco Code Desktop 路径："
    printf '    %s\n' "${REGISTERED[@]}"
    exit 1
fi

say ""
say "启动：open \"$DEST_APP\""
