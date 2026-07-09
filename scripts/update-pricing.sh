#!/usr/bin/env bash
# 手动运行，联网拉取 LiteLLM 定价表并写回仓库。产物需提交。
set -euo pipefail

URL="https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json"
OUT="Sources/TokenMeterCore/Resources/litellm-pricing.json"

mkdir -p "$(dirname "$OUT")"
curl -fsSL "$URL" | python3 scripts/transform_pricing.py > "$OUT"

count=$(python3 -c "import json;print(len(json.load(open('$OUT'))['models']))")
echo "wrote $OUT with $count models"
