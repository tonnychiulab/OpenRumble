#!/bin/bash
# OpenRumble 第二階段 TUI 啟動器。
# 只負責把終端交給 Node 程式；部署、回滾、複查仍由倉庫根目錄的 bash 腳本執行。
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENTRY="${DIR}/dist/main.js"

if ! command -v node >/dev/null 2>&1; then
    echo "需要 Node.js 18 以上。請先安裝 Node，並在 phase2-tui 執行 npm install && npm run build。" >&2
    exit 1
fi

if [[ ! -f "$ENTRY" ]]; then
    echo "找不到 ${ENTRY}。請在 phase2-tui 目錄執行 npm install && npm run build。" >&2
    exit 1
fi

exec node "$ENTRY" "$@"
