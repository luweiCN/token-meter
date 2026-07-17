#!/usr/bin/env bash
# 正式安装：调 build-app.sh 做 release 构建，然后装进 /Applications、
# 注册开机自启的 LaunchAgent。构建逻辑全部在 build-app.sh（CI 同源）。
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_APP_DIR="$ROOT_DIR/build/TokenMeter.app"
INSTALL_APP_DIR="/Applications/TokenMeter.app"
BUNDLE_ID="com.luwei.tokenmeter"
LAUNCH_AGENT_PLIST="$HOME/Library/LaunchAgents/$BUNDLE_ID.plist"

"$ROOT_DIR/scripts/build-app.sh"

# 停掉旧实例（若在跑），换成新的一份。Electron 主界面也要杀：
# 旧进程引用的 Resources/Electron 马上会被整目录替换，留着必白屏。
osascript -e 'tell application "TokenMeter" to quit' 2>/dev/null || true
pkill -f "$INSTALL_APP_DIR/Contents/MacOS/TokenMeterApp" 2>/dev/null || true
pkill -f "$INSTALL_APP_DIR/Contents/Resources/Electron" 2>/dev/null || true
sleep 1
rm -rf "$INSTALL_APP_DIR"
cp -R "$BUILD_APP_DIR" "$INSTALL_APP_DIR"

# 开机自启：写一个 LaunchAgent，登录时以当前用户身份拉起菜单栏程序。
# 只设 RunAtLoad，不设 KeepAlive——用户手动退出时不该被强行拉起来。
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$LAUNCH_AGENT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$BUNDLE_ID</string>
    <key>ProgramArguments</key>
    <array>
        <string>$INSTALL_APP_DIR/Contents/MacOS/TokenMeterApp</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>LimitLoadToSessionType</key>
    <string>Aqua</string>
</dict>
</plist>
PLIST

launchctl bootout "gui/$(id -u)/$BUNDLE_ID" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$LAUNCH_AGENT_PLIST"
launchctl enable "gui/$(id -u)/$BUNDLE_ID"

echo "$INSTALL_APP_DIR"
