#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
args=(-s -w)
if [[ -n "${TOKEN_METER_CLI_VERSION:-}" ]]; then
  args+=(-X "main.version=$TOKEN_METER_CLI_VERSION")
fi
CGO_ENABLED=0 go build -trimpath -ldflags "${args[*]}" -o "${1:?specify an output path}" ./CLI
