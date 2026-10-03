#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
app_path="$project_dir/.build/云写君.app"
executable_path="$app_path/Contents/MacOS/云写君"
# 沿用旧构建普通启动，不因可执行文件改名而自动重建。
if [[ ${1:-} != "--rebuild" && ! -f "$executable_path" && -f "$app_path/Contents/MacOS/Typeless01 App" ]]; then
    executable_path="$app_path/Contents/MacOS/Typeless01 App"
fi
running_executable="$executable_path"
if [[ ! -f "$running_executable" && -f "$app_path/Contents/MacOS/Typeless01 App" ]]; then
    running_executable="$app_path/Contents/MacOS/Typeless01 App"
fi
legacy_executable="$project_dir/.build/Typeless01 App.app/Contents/MacOS/Typeless01 App"

# 旧版本仍运行时不再启动第二份应用；先正常退出，再构建改名版本。
if [[ -f "$legacy_executable" ]] && /usr/sbin/lsof -F f "$legacy_executable" 2>/dev/null | /usr/bin/awk '$0 == "ftxt" { running = 1 } END { exit !running }'; then
    printf '%s\n' '旧名称的应用仍在运行。请在旧应用菜单中选择退出，再运行本脚本启动云写君。'
    exit 0
fi

if [[ $# -gt 1 || ( $# -eq 1 && "$1" != "--rebuild" ) ]]; then
    printf '%s\n' '用法：./Scripts/run-app.sh [--rebuild]' >&2
    exit 2
fi

# 已运行时只唤回同一份应用，避免产生两个菜单栏入口。
# 权限进程 tccd 也会以普通文件方式打开旧程序；只有 txt 映射才是运行中的可执行文件。
if [[ -f "$running_executable" ]] && /usr/sbin/lsof -F f "$running_executable" 2>/dev/null | /usr/bin/awk '$0 == "ftxt" { running = 1 } END { exit !running }'; then
    printf '%s\n' '应用已在运行，将唤回已有窗口。修改代码后，请先在应用菜单中退出，再运行本脚本。'
    open "$app_path"
    exit 0
fi

# 平时直接启动已经签过名的应用，不重新构建或签名；
# 源码修改后由开发者明确传入 --rebuild，避免 macOS 反复撤销旧授权。
if [[ ${1:-} != "--rebuild" && -f "$executable_path" ]] \
    && codesign --verify --strict "$app_path" >/dev/null 2>&1; then
    open "$app_path"
    printf '%s\n' '已沿用现有签名启动云写君；修改代码后请退出应用，再运行 ./Scripts/run-app.sh --rebuild。'
    exit 0
fi

cd "$project_dir"
swift build
binary_dir="$(swift build --show-bin-path)"
mkdir -p "$app_path/Contents/MacOS"
mkdir -p "$app_path/Contents/Resources"
cp "$project_dir/Configuration/Assets/AppIcon.icns" "$app_path/Contents/Resources/AppIcon.icns"
executable_path="$app_path/Contents/MacOS/云写君"
cp "$binary_dir/云写君" "$executable_path"
chmod +x "$executable_path"
cp "$project_dir/Configuration/Info.plist" "$app_path/Contents/Info.plist"
plutil -lint "$app_path/Contents/Info.plist"
# 为整个应用包绑定标识，避免只有可执行文件的临时签名导致权限识别不一致。
# 本地临时签名不是发布签名；重新构建后 macOS 仍可能要求重新授权。
codesign --force --sign - --identifier local.typeless01.app "$app_path"
codesign --verify --strict "$app_path"
open "$app_path"
printf '%s\n' '已启动云写君。菜单栏入口为“波形＋云写君”；也可在左上角应用菜单打开设置。'
