#!/usr/bin/env bash
# 正式安装：release 构建、装进 /Applications、注册开机自启的 LaunchAgent。
#
# 跟 package-dev-app.sh 的区别只有三处：release 而非 debug 构建、装到
# /Applications 而不是留在 build/ 目录里、多一步 LaunchAgent 注册。
# 打包逻辑本身（拷贝 bundle、在副本里重建 native 模块、ad-hoc 签名）沿用
# package-dev-app.sh 已验证过的做法。
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_APP_DIR="$ROOT_DIR/build/TokenMeter.app"
INSTALL_APP_DIR="/Applications/TokenMeter.app"
CONTENTS_DIR="$BUILD_APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
BUNDLE_ID="com.luwei.tokenmeter"
LAUNCH_AGENT_PLIST="$HOME/Library/LaunchAgents/$BUNDLE_ID.plist"

cd "$ROOT_DIR"
swift build -c release
npm install --prefix "$ROOT_DIR/Electron"
npm run build --prefix "$ROOT_DIR/Electron"

rm -rf "$BUILD_APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$ROOT_DIR/.build/release/TokenMeterApp" "$MACOS_DIR/TokenMeterApp"
cp "$ROOT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
# hooks 上报脚本：Claude/Codex 的 hook 条目直接引用 bundle 内路径（Muxy 同款做法），
# OMP 的 TS 扩展由注入器从这里拷到 ~/.omp/agent/extensions/。
cp -R "$ROOT_DIR/Resources/hooks" "$RESOURCES_DIR/hooks"
chmod +x "$RESOURCES_DIR/hooks/tokenmeter-agent-hook.sh"

# 应用图标：TokenMeter.app 自身（Finder/启动台）与内嵌 Electron.app（Dock/Cmd-Tab）
# 都换成品牌图。此处在 codesign 之前，签名会把改动一并覆盖。
cp "$ROOT_DIR/Resources/branding/TokenMeter.icns" "$RESOURCES_DIR/TokenMeter.icns"

# 整份拷贝进 Resources，native 模块只在这份副本里重建为 Electron ABI——
# 绝不触碰仓库里 Electron/node_modules 本身（那份要留给 npm test 用 Node ABI）。
cp -R "$ROOT_DIR/Electron" "$RESOURCES_DIR/Electron"
cp "$ROOT_DIR/Resources/branding/TokenMeter.icns" \
   "$RESOURCES_DIR/Electron/node_modules/electron/dist/Electron.app/Contents/Resources/electron.icns"
npm run rebuild:native --prefix "$RESOURCES_DIR/Electron" -- -f -w better-sqlite3 --build-from-source
node "$RESOURCES_DIR/Electron/node_modules/electron/cli.js" --version >/dev/null

# 签名必须在拷贝这两个资源包【之前】：codesign --deep 见到 bundle 根目录下的
# 松散文件夹会直接报错退出（实测 exit 1）。package-dev-app.sh 已验证过的顺序
# 就是先签、后加——这两个 SPM 资源包因此留在签名之外，是既有的、可用的状态。
codesign --remove-signature "$BUILD_APP_DIR" 2>/dev/null || true
codesign --force --deep --sign - --identifier "$BUNDLE_ID" "$BUILD_APP_DIR" >/dev/null
cp -R "$ROOT_DIR/.build/release/TokenMeter_TokenMeterApp.bundle" "$BUILD_APP_DIR/TokenMeter_TokenMeterApp.bundle"
cp -R "$ROOT_DIR/.build/release/TokenMeter_TokenMeterCore.bundle" "$BUILD_APP_DIR/TokenMeter_TokenMeterCore.bundle"

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
