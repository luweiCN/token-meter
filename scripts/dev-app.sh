#!/usr/bin/env bash
# 主界面开发模式：改完即见，不用重装。
#
#   ./scripts/dev-app.sh
#
# - renderer（src/renderer 里的 React / CSS）→ vite HMR，保存即热更新，窗口不重启
# - 主进程 / preload（src/main、src/preload.ts）→ tsc/vite 自动重编，但要 Ctrl-C 重跑本脚本生效
# - Swift 菜单栏不在此列（原生程序，仍走 scripts/install-app.sh）
# - 数据直连生产库（~/.token-meter），看到的就是真实数据
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../Electron"

PORT=5273

# preload 与主进程先各构建一次（electron 启动即需要磁盘上的产物）
npx vite build --mode preload > /dev/null
npm run build --silent > /dev/null 2>&1 || true

npx vite --host 127.0.0.1 --port "$PORT" &
VITE_PID=$!

# 主进程 TS 持续重编（复刻 build 的编译参数）；改动后 Ctrl-C 重跑本脚本
npx tsc --outDir dist-main --rootDir src --module NodeNext --moduleResolution NodeNext \
  --target ES2022 --skipLibCheck --types node --strict --esModuleInterop --jsx react-jsx \
  --watch --preserveWatchOutput src/main/main.ts src/main/ipc.ts > /dev/null &
TSC_PID=$!

trap 'kill $VITE_PID $TSC_PID 2>/dev/null || true' EXIT

sleep 1.5
VITE_DEV_SERVER_URL="http://127.0.0.1:$PORT" npx electron .
