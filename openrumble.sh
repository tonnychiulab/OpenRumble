#!/bin/bash
# ==============================================================================
# Script Name   : openrumble.sh
# Description   : OpenRumble TUI。只顯示狀態並呼叫同目錄的獨立腳本。
# Repository    : https://github.com/tonnychiulab/OpenRumble
# Target Platform: Ubuntu 24.04 LTS (Kernel 6.8+ BTF)
# Author        : 資安防禦架構實驗室
# Version       : v2.1.0
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/obm_common.sh
source "$SCRIPT_DIR/lib/obm_common.sh"

C_RED="${ESC}[1;31m"
C_GREEN="${ESC}[1;32m"
C_YELLOW="${ESC}[1;33m"
C_CYAN="${ESC}[1;36m"
C_WHITE="${ESC}[1;37m"
C_MAGENTA="${ESC}[1;35m"
C_BG_BLUE="${ESC}[44;37m"
C_DIM="${ESC}[2m"

usage() {
    echo "使用方式: $0 [--help]"
    echo "  倉庫: https://github.com/tonnychiulab/OpenRumble"
    echo "  開啟 OpenRumble 主控台。實際部署、回滾與複查交給同目錄腳本，並顯示其離開碼。"
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

get_status_badge() {
    local service_name="$1"
    if systemctl is-active --quiet "$service_name" 2>/dev/null; then
        echo -e "${C_GREEN}● RUNNING${C_RESET}"
    else
        echo -e "${C_RED}○ STOPPED${C_RESET}"
    fi
}

get_zeek_badge() {
    if [ ! -x /opt/zeek/bin/zeekctl ]; then
        echo -e "${C_DIM}○ NOT INSTALLED${C_RESET}"
        return 0
    fi
    local status
    status="$(/opt/zeek/bin/zeekctl status 2>/dev/null || true)"
    if [[ "$status" == *running* ]]; then
        echo -e "${C_GREEN}● RUNNING${C_RESET}"
    else
        echo -e "${C_YELLOW}○ INSTALLED/STOPPED${C_RESET}"
    fi
}

render_tui_menu() {
    clear || true
    local btf_badge
    if [ -r /sys/kernel/btf/vmlinux ]; then
        btf_badge="${C_GREEN}SUPPORTED${C_RESET}"
    else
        btf_badge="${C_RED}MISSING${C_RESET}"
    fi

    echo -e "${C_BG_BLUE}  === OpenRumble 執行時期安全防護 TUI 主控台 ===  ${C_RESET}"
    echo -e "${C_DIM}系統環境: Ubuntu 24.04 LTS | 核心: $(uname -r) | 選單版 v2.1.0${C_RESET}"
    echo -e "----------------------------------------------------------------------"
    echo -e "【即時防禦狀態看板】"
    echo -e "  • Linux 核心 BTF (Modern eBPF) : ${btf_badge}"
    echo -e "  • Falco (Modern eBPF 探針)     : $(get_status_badge falco-modern-bpf)"
    echo -e "  • Linux Auditd (稽核證據鏈)     : $(get_status_badge auditd)"
    echo -e "  • Zeek (L3/L4/L7 流量分析)      : $(get_zeek_badge)"
    echo -e "----------------------------------------------------------------------"
    echo -e "${C_WHITE}請選擇要執行的作業項目：${C_RESET}"
    echo -e "  ${C_CYAN}[1]${C_RESET} 部署第一階段防線 (Falco Modern eBPF + Audit Log + Logrotate)"
    echo -e "  ${C_CYAN}[2]${C_RESET} 第一階段部署 Dry-Run 模擬預檢 (不修改系統)"
    echo -e "  ${C_CYAN}[3]${C_RESET} 執行第一階段自動化複查 (靜態檢驗 + 紅藍攻防打靶)"
    echo -e "  ${C_RED}[4]${C_RESET} 一鍵回滾第一階段設定 (保留套件，還原原生設定檔)"
    echo -e "  ${C_RED}[5]${C_RESET} 徹底清除第一階段 (回滾設定 + 完全卸載 Falco 套件)"
    echo -e "  ${C_BLUE}--- 第二階段網路流量擴充（完整 TUI） ---${C_RESET}"
    echo -e "  ${C_CYAN}[6]${C_RESET} 進入 Zeek TUI，停在正式部署"
    echo -e "  ${C_CYAN}[7]${C_RESET} 進入 Zeek TUI，停在 Dry-Run 預檢"
    echo -e "  ${C_CYAN}[10]${C_RESET} 進入 Zeek TUI，停在唯讀複查"
    echo -e "  ${C_RED}[8]${C_RESET} 進入 Zeek TUI，停在回滾設定"
    echo -e "  ${C_RED}[9]${C_RESET} 進入 Zeek TUI，停在卸載套件（刪除 /opt/zeek 要另外輸入 DELETE）"
    echo -e "  ${C_MAGENTA}[0]${C_RESET} 離開控制台 (Exit)"
    echo -e "----------------------------------------------------------------------"
}

launch_phase2_tui() {
    local select_action="${1:-}"
    local launcher="${SCRIPT_DIR}/phase2-tui/obm-zeek-tui.sh"
    if [[ ! -f "$launcher" ]]; then
        log_error "找不到第二階段 TUI：${launcher}"
        return 0
    fi
    log_info "啟動第二階段 Zeek TUI（部署、回滾、複查仍由獨立腳本執行）"
    local rc=0
    set +e
    if [[ -r /dev/tty && -w /dev/tty ]]; then
        if [[ -n "$select_action" ]]; then
            bash "$launcher" --select "$select_action" < /dev/tty > /dev/tty 2>&1
        else
            bash "$launcher" < /dev/tty > /dev/tty 2>&1
        fi
        rc=$?
    else
        if [[ -n "$select_action" ]]; then
            bash "$launcher" --select "$select_action"
        else
            bash "$launcher"
        fi
        rc=$?
    fi
    set -e
    if [[ "$rc" -eq 0 ]]; then
        log_success "第二階段 TUI 結束，離開碼 ${rc}"
    else
        log_error "第二階段 TUI 結束，離開碼 ${rc}"
    fi
}

run_script() {
    local description="$1"
    shift
    set +e
    "$@"
    local rc=$?
    set -e
    if [ "$rc" -eq 0 ]; then
        log_success "${description} 完成，離開碼 ${rc}"
    else
        log_error "${description} 失敗，離開碼 ${rc}"
    fi
}

prompt_enter() {
    echo -e "\n${C_DIM}按下 [Enter] 鍵返回主選單...${C_RESET}"
    read -r _ || true
}

main() {
    obm_require_root
    local session_log
    session_log="obm_tui_session_$(date +%Y%m%d_%H%M%S).log"
    obm_init_logging "$session_log"

    if [ -f /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        if [[ "${ID:-}" != "ubuntu" ]] || [[ "${VERSION_ID:-}" != "24.04" ]]; then
            echo -e "${C_YELLOW}[!] 警告: 本工具基準為 Ubuntu 24.04 LTS，當前系統為: ${NAME:-Unknown} ${VERSION_ID:-Unknown}${C_RESET}"
            if ! obm_confirm "是否強制進入控制台？ [y/N]: "; then
                exit 1
            fi
        fi
    fi

    while true; do
        render_tui_menu
        read -r -p "請輸入選項編號 [0-10]: " choice || break
        case "$choice" in
            1)
                run_script "第一階段部署" bash "$SCRIPT_DIR/scripts/phase1/deploy_phase1_runtime_guard.sh" --yes
                ;;
            2)
                run_script "第一階段 Dry-Run" bash "$SCRIPT_DIR/scripts/phase1/deploy_phase1_runtime_guard.sh" --dry-run
                ;;
            3)
                run_script "第一階段複查" bash "$SCRIPT_DIR/scripts/phase1/verify_phase1_runtime_guard.sh"
                ;;
            4)
                if obm_confirm "確認要還原第一階段設定檔嗎？ [y/N]: "; then
                    run_script "第一階段回滾" bash "$SCRIPT_DIR/scripts/phase1/rollback_phase1_runtime_guard.sh" --yes
                fi
                ;;
            5)
                if obm_confirm "資安警示：即將完全解除安裝 Falco，確認？ [y/N]: "; then
                    run_script "第一階段清除" bash "$SCRIPT_DIR/scripts/phase1/rollback_phase1_runtime_guard.sh" --yes --purge-packages
                fi
                ;;
            6)
                launch_phase2_tui "deploy"
                ;;
            7)
                launch_phase2_tui "dry-run"
                ;;
            10)
                launch_phase2_tui "verify"
                ;;
            8)
                launch_phase2_tui "rollback"
                ;;
            9)
                launch_phase2_tui "purge-packages"
                ;;
            0|q|Q)
                echo -e "\n${C_GREEN}感謝使用，安全退出控制台。日誌已存至: $PWD/$session_log${C_RESET}"
                exit 0
                ;;
            *)
                echo -e "${C_RED}無效選項，請重新輸入！${C_RESET}"
                ;;
        esac
        prompt_enter
    done
}

main "$@"
