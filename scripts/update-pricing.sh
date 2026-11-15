#!/usr/bin/env bash
# 本地与 CI 共用：联网拉取 LiteLLM 定价表，生成随包快照。契约见 docs/pricing.md。
set -euo pipefail

URL="https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json"
OUT="Sources/TokenMeterCore/Resources/litellm-pricing.json"

mkdir -p "$(dirname "$OUT")"

# 原子写。`> "$OUT"` 在打开时就截断文件，抓取一旦中断（超时、断网、Ctrl-C）
# 就会在磁盘上留下一个空快照，而 loadBundled() 只在运行时才会发现。
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
curl -fsSL --retry 3 --retry-all-errors --connect-timeout 15 "$URL" \
  | python3 scripts/transform_pricing.py scripts/pricing-overrides.json > "$TMP"
mv "$TMP" "$OUT"

count=$(python3 -c "import json;print(len(json.load(open('$OUT'))['models']))")
echo "wrote $OUT with $count models"
