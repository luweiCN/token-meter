#!/usr/bin/env bash
# 构建完整的 release 版 TokenMeter.app 到 build/（不安装、不动系统状态）。
# install-app.sh（本地安装）与 .github/workflows/release.yml（CI 发布）都调这一份，
# 构建逻辑永远只有一处。打包细节（先签名后拷 SPM 资源包、在副本里重建
# native 模块）沿用 package-dev-app.sh 验证过的做法，注释见各步骤。
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_APP_DIR="$ROOT_DIR/build/TokenMeter.app"
CONTENTS_DIR="$BUILD_APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
BUNDLE_ID="com.luwei.tokenmeter"

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

echo "$BUILD_APP_DIR"
