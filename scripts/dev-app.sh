#!/usr/bin/env bash
# 主界面开发模式：改 UI 即时生效，不用重装。
#
#   ./scripts/dev-app.sh
#
# 结构：renderer 由 vite 从【仓库源码】热更新（src/renderer 保存即生效）；
# 主进程/preload 用【安装 bundle】里的产物——那份的 better-sqlite3 已按
# Electron ABI 重编（仓库 node_modules 留给 vitest 的 Node ABI，两不相扰）。
# 因此改 src/main、src/preload.ts 后需先 ./scripts/install-app.sh 再进 dev。
#
# dev 实例用独立用户数据目录（main.ts 里按 VITE_DEV_SERVER_URL 切换），
# 可与正式版同开，互不干扰。
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE_ELECTRON="/Applications/TokenMeter.app/Contents/Resources/Electron"
PORT=5273

if [ ! -d "$BUNDLE_ELECTRON/node_modules/electron" ]; then
  echo "未找到安装版（$BUNDLE_ELECTRON）。先运行 ./scripts/install-app.sh"
  exit 1
fi

cd "$ROOT_DIR/Electron"
npx vite --host 127.0.0.1 --port "$PORT" &
VITE_PID=$!
trap 'kill $VITE_PID 2>/dev/null || true' EXIT

sleep 1.5
cd "$BUNDLE_ELECTRON"
VITE_DEV_SERVER_URL="http://127.0.0.1:$PORT" npx electron .
