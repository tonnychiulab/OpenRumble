#!/bin/bash
# ==============================================================================
# Script Name   : verify_phase1_runtime_guard.sh
# Description   : OpenRumble 第一階段：執行時期防禦矩陣自動化複查與攻防驗證
# Target Platform: Ubuntu 24.04 LTS (Kernel 6.8+ BTF)
# Author        : 資安防禦架構實驗室
# ==============================================================================
# Version History:
#   v1.1.0 (2026-11-03) - 必須為 root；打靶檔僅含註解，EXIT/INT/TERM 都會刪除；
#                         Falco 與 ausearch 只接受本次開始之後的事件。
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/obm_common.sh
source "$SCRIPT_DIR/lib/obm_common.sh"

usage() {
    echo "使用方式: $0 [--help]"
    echo "  複查會短暫寫入 /etc/sudoers.d/99-obm-audit-test-*（僅註解），結束或中斷時刪除。"
    echo "  --help, -h  顯示此說明訊息"
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

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
AUDIT_REPORT="obm_phase1_audit_report_${TIMESTAMP}.txt"
obm_init_logging "$AUDIT_REPORT"

TARGET_FILE=""
cleanup_target() {
    if [ -n "${TARGET_FILE:-}" ] && [ -e "$TARGET_FILE" ]; then
        rm -f "$TARGET_FILE"
    fi
}
trap cleanup_target EXIT
trap 'cleanup_target; exit 130' INT
trap 'cleanup_target; exit 143' TERM

pass_count=0
fail_count=0

audit_assert() {
    local desc="$1"
    local status="$2"
    if [ "$status" -eq 0 ]; then
        echo -e "${C_GREEN}[PASS] ${desc}${C_RESET}"
        pass_count=$((pass_count + 1))
    else
        echo -e "${C_RED}[FAIL] ${desc}${C_RESET}"
        fail_count=$((fail_count + 1))
    fi
}

check_cmd() {
    local desc="$1"
    shift
    if "$@"; then
        audit_assert "$desc" 0
    else
        audit_assert "$desc" 1
    fi
}

falco_saw_rule_since() {
    local file="$1"
    local start_epoch="$2"
    local needle="$3"
    [ -f "$file" ] || return 1
    python3 - "$file" "$start_epoch" "$needle" <<'PY'
import json
import sys
from datetime import datetime, timezone

path, start_s, needle = sys.argv[1:]
start = int(start_s)

def parse_time(ts):
    if ts.endswith("Z"):
        ts = ts[:-1] + "+00:00"
    if "." in ts:
        head, tail = ts.split(".", 1)
        digits = []
        i = 0
        while i < len(tail) and tail[i].isdigit():
            digits.append(tail[i])
            i += 1
        frac = "".join(digits)[:6]
        ts = head + "." + frac + tail[i:]
    dt = datetime.fromisoformat(ts)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.timestamp()

with open(path, encoding="utf-8", errors="replace") as handle:
    for raw in handle:
        raw = raw.strip()
        if not raw:
            continue
        try:
            event = json.loads(raw)
        except json.JSONDecodeError:
            continue
        blob = raw
        if needle not in blob:
            continue
        try:
            if parse_time(str(event.get("time") or "")) >= start:
                sys.exit(0)
        except (TypeError, ValueError):
            continue
sys.exit(1)
PY
}

main() {
    obm_require_root
    obm_check_ubuntu_2404 warn
    obm_acquire_lock

    echo -e "${C_BLUE}==================================================================${C_RESET}"
    echo -e "${C_BLUE}   OpenRumble 第一階段：自動化複查與防線稽核程序        ${C_RESET}"
    echo -e "${C_BLUE}   複查報告: $PWD/$AUDIT_REPORT                                  ${C_RESET}"
    echo -e "${C_BLUE}==================================================================${C_RESET}"

    echo -e "\n${C_YELLOW}>>> [階段 1] 靜態系統基準與核心 eBPF 支援複查...${C_RESET}"
    check_cmd "Linux 核心 BTF (/sys/kernel/btf/vmlinux) 存在" test -r /sys/kernel/btf/vmlinux
    check_cmd "Falco Modern eBPF 服務狀態 (active)" systemctl is-active --quiet falco-modern-bpf
    check_cmd "Linux Auditd 稽核服務狀態 (active)" systemctl is-active --quiet auditd
    check_cmd "Auditd 已載入 identity_changes 規則" bash -c 'auditctl -l 2>/dev/null | grep -q identity_changes'
    check_cmd "Auditd 已載入 priv_escalation 規則" bash -c 'auditctl -l 2>/dev/null | grep -q priv_escalation'
    check_cmd "Falco 日誌輪替設定 (/etc/logrotate.d/falco) 語法無誤" bash -c 'logrotate -d /etc/logrotate.d/falco >/dev/null 2>&1'

    echo -e "\n${C_YELLOW}>>> [階段 2] 動態打靶模擬與雙向日誌關聯複查...${C_RESET}"
    TARGET_FILE="/etc/sudoers.d/99-obm-audit-test-${TIMESTAMP}"
    local start_epoch start_stamp
    start_epoch=$(date +%s)
    start_stamp=$(date -d "@${start_epoch}" '+%m/%d/%Y %H:%M:%S')

    echo -e "${C_BLUE}[*] 模擬紅隊行為：寫入僅含註解的 sudoers 片段並立即刪除...${C_RESET}"
    printf '%s\n' '# OpenRumble phase 1 audit test. Safe to delete.' > "$TARGET_FILE"
    chmod 0440 "$TARGET_FILE"
    sleep 1
    rm -f "$TARGET_FILE"

    echo -e "${C_BLUE}[*] 等待核心探針捕捉事件與日誌落地 (約 2 秒)...${C_RESET}"
    sleep 2

    if falco_saw_rule_since /var/log/falco_events.json "$start_epoch" "$TARGET_FILE"; then
        audit_assert "Falco 偵測到本次 Sudoers 修改行為並寫入 JSON 日誌" 0
    else
        audit_assert "Falco 偵測到本次 Sudoers 修改行為並寫入 JSON 日誌" 1
    fi

    local audit_hit=""
    audit_hit="$(ausearch -k identity_changes -ts "$start_stamp" 2>/dev/null || true)"
    if [[ "$audit_hit" == *"$TARGET_FILE"* ]]; then
        audit_assert "Auditd 鑑識日誌捕獲本次目標檔案操作與原始身分 (auid)" 0
    else
        audit_assert "Auditd 鑑識日誌捕獲本次目標檔案操作與原始身分 (auid)" 1
    fi

    echo -e "\n${C_YELLOW}>>> [階段 3] 測試殘留與安全狀態清理...${C_RESET}"
    rm -f "$TARGET_FILE"
    if [ ! -f "$TARGET_FILE" ]; then
        audit_assert "打靶測試檔案已安全抹除" 0
    else
        audit_assert "打靶測試檔案已安全抹除" 1
    fi

    echo -e "\n${C_BLUE}==================================================================${C_RESET}"
    echo -e "   複查結果摘要: 通過 [ ${C_GREEN}${pass_count}${C_RESET} ] / 失敗 [ ${C_RED}${fail_count}${C_RESET} ]"
    if [ "$fail_count" -eq 0 ]; then
        echo -e "${C_GREEN}[SUCCESS] 第一階段防禦矩陣自動化複查合格。${C_RESET}"
        exit 0
    fi
    echo -e "${C_RED}[WARNING] 部分檢查項目未通過，請檢視詳細日誌排查原因。${C_RESET}"
    echo -e "${C_BLUE}==================================================================${C_RESET}"
    exit 1
}

main "$@"
