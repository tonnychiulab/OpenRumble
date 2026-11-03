#!/bin/bash
# ==============================================================================
# Script Name   : verify_phase2_zeek.sh
# Description   : OpenRumble 第二階段唯讀複查。
#                 檢查 zeekctl、介面、JSON 設定、current 日誌與輪替設定。
#                 不改系統、不抓封包、不呼叫 zeekctl deploy。
# Target Platform: Ubuntu 24.04 LTS (Noble Numbat)
# Author        : 資安防禦架構實驗室
# ==============================================================================
# Version History:
#   v2.0.0 (2026-11-03) - 初版。只讀檢查，失敗項目會計入離開碼，不中途改檔。
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/obm_common.sh
source "${SCRIPT_DIR}/lib/obm_common.sh"

usage() {
    cat <<'EOF'
使用方式: verify_phase2_zeek.sh [--help]
  唯讀複查 Zeek 是否在跑、node.cfg 的介面是否仍存在、
  local.zeek 是否啟用 JSON、current 日誌是否已有 JSON 行、
  以及 zeekctl cron 或歸檔 logrotate 是否存在。
  不修改系統，不抓封包。

離開碼: 0 全部通過，1 有項目失敗或環境不符。
EOF
}

for arg in "$@"; do
    case "$arg" in
        --help|-h)
            usage
            exit 0
            ;;
        *)
            log_error "未知參數: $arg"
            usage
            exit 1
            ;;
    esac
done

pass_count=0
fail_count=0

audit_assert() {
    local desc="$1"
    local status="$2"
    if [[ "$status" -eq 0 ]]; then
        echo -e "${GREEN}[PASS] ${desc}${NC}"
        pass_count=$((pass_count + 1))
    else
        echo -e "${RED}[FAIL] ${desc}${NC}"
        fail_count=$((fail_count + 1))
    fi
}

echo -e "${BLUE}==================================================================${NC}"
echo -e "${BLUE}   OpenRumble 第二階段：Zeek 唯讀複查                  ${NC}"
echo -e "${BLUE}==================================================================${NC}"

obm_require_root
obm_require_ubuntu_2404

echo -e "\n${YELLOW}>>> 服務與設定${NC}"

status_text=""
if [[ -x /opt/zeek/bin/zeekctl ]]; then
    status_text="$(/opt/zeek/bin/zeekctl status 2>/dev/null || true)"
fi
if [[ "$status_text" == *running* ]]; then
    audit_assert "zeekctl status 顯示 running" 0
else
    audit_assert "zeekctl status 顯示 running" 1
fi

iface=""
if [[ -f /opt/zeek/etc/node.cfg ]]; then
    iface="$(awk -F= '/^[[:space:]]*interface=/ { gsub(/[[:space:]]/, "", $2); print $2; exit }' /opt/zeek/etc/node.cfg)"
fi
if [[ -n "$iface" ]] && ip link show dev "$iface" >/dev/null 2>&1; then
    audit_assert "node.cfg 介面 ${iface} 仍存在" 0
else
    audit_assert "node.cfg 介面存在（目前: ${iface:-未設定}）" 1
fi

if [[ -f /opt/zeek/share/zeek/site/local.zeek ]] \
    && grep -q "LogAscii::use_json" /opt/zeek/share/zeek/site/local.zeek \
    && grep -q "json-logs.zeek" /opt/zeek/share/zeek/site/local.zeek; then
    audit_assert "local.zeek 已啟用 JSON 日誌" 0
else
    audit_assert "local.zeek 已啟用 JSON 日誌" 1
fi

echo -e "\n${YELLOW}>>> 日誌與輪替${NC}"

json_line=1
if compgen -G "/opt/zeek/logs/current/*.log" > /dev/null; then
    if grep -l -m 1 '^{' /opt/zeek/logs/current/*.log >/dev/null 2>&1; then
        json_line=0
    fi
fi
audit_assert "current 日誌目錄有 JSON 行" "$json_line"

cron_ok=1
if [[ -f /etc/cron.d/obm-zeek ]] && grep -q "/opt/zeek/bin/zeekctl cron" /etc/cron.d/obm-zeek; then
    cron_ok=0
fi
rotate_ok=1
if [[ -f /etc/logrotate.d/zeek ]]; then
    rotate_ok=0
fi
if [[ "$cron_ok" -eq 0 || "$rotate_ok" -eq 0 ]]; then
    audit_assert "zeekctl cron 或 logrotate 設定存在" 0
else
    audit_assert "zeekctl cron 或 logrotate 設定存在" 1
fi

unsafe_rotate=1
if [[ -f /etc/logrotate.d/zeek ]] \
    && grep -q "/opt/zeek/logs/current" /etc/logrotate.d/zeek \
    && grep -q "copytruncate" /etc/logrotate.d/zeek; then
    unsafe_rotate=0
fi
if [[ "$unsafe_rotate" -eq 0 ]]; then
    audit_assert "logrotate 沒有對 current/ 使用 copytruncate" 1
else
    audit_assert "logrotate 沒有對 current/ 使用 copytruncate" 0
fi

echo -e "\n${BLUE}==================================================================${NC}"
echo -e "   複查結果: 通過 [ ${GREEN}${pass_count}${NC} ] / 失敗 [ ${RED}${fail_count}${NC} ]"
if [[ "$fail_count" -eq 0 ]]; then
    echo -e "${GREEN}[SUCCESS] 第二階段唯讀複查通過。${NC}"
    exit 0
fi
echo -e "${RED}[WARNING] 有檢查項目未通過。此腳本沒有修改系統。${NC}"
echo -e "${BLUE}==================================================================${NC}"
exit 1
