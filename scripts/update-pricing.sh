#!/usr/bin/env bash
# 手动运行，联网拉取 LiteLLM 定价表并写回仓库。产物需提交。
set -euo pipefail

URL="https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json"
OUT="Sources/TokenMeterCore/Resources/litellm-pricing.json"

mkdir -p "$(dirname "$OUT")"

# 原子写。`> "$OUT"` 在打开时就截断文件，抓取一旦中断（超时、断网、Ctrl-C）
# 就会在磁盘上留下一个空快照，而 loadBundled() 只在运行时才会发现。
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
curl -fsSL "$URL" | python3 scripts/transform_pricing.py > "$TMP"
mv "$TMP" "$OUT"

count=$(python3 -c "import json;print(len(json.load(open('$OUT'))['models']))")
echo "wrote $OUT with $count models"
