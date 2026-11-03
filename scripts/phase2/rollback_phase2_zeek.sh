#!/bin/bash
# ==============================================================================
# Script Name   : scripts/phase2/rollback_phase2_zeek.sh
# Description   : OpenRumble 第二階段 Zeek 回滾。
#                 --purge-packages 只移除 zeek 套件、OBS 來源與金鑰，保留 jq。
#                 --purge 才會刪除 /opt/zeek，而且預設要再確認一次。
#                 不修改、也不還原登入殼層 PATH。
# Target Platform: Ubuntu 24.04 LTS (Noble Numbat)
# Author        : 資安防禦架構實驗室
# ==============================================================================
# Version History:
#   v2.0.0 (2026-11-03) - 失敗即停、.bak_orig、--yes / --dry-run / --purge-packages / --purge。
#                         不再卸載 jq，不再動登入殼層 PATH。
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=../../lib/obm_common.sh
source "${REPO_ROOT}/lib/obm_common.sh"

DRY_RUN_MODE=false
YES_MODE=false
PURGE_PACKAGES=false
PURGE_TREE=false

ZEEK_LIST="/etc/apt/sources.list.d/security:zeek.list"
ZEEK_KEYRING="/usr/share/keyrings/security_zeek.gpg"
ZEEKCTL="/opt/zeek/bin/zeekctl"
CRON_FILE="/etc/cron.d/obm-zeek"

usage() {
    cat <<'EOF'
使用方式: rollback_phase2_zeek.sh [--dry-run] [--yes] [--purge-packages] [--purge]
  --dry-run           只列出預計還原與刪除的路徑，不修改系統
  --yes               略過互動確認（TUI 會先確認再帶這個旗標）
  --purge-packages    額外卸載 zeek 套件、OBS 來源與金鑰。不卸載 jq，不執行 autoremove
  --purge             額外刪除 /opt/zeek（含日誌）。沒有 --yes 時必須輸入 DELETE
  --help, -h          顯示說明

離開碼: 0 完成，1 失敗，2 操作者中止。
EOF
}

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN_MODE=true ;;
        --yes) YES_MODE=true ;;
        --purge-packages) PURGE_PACKAGES=true ;;
        --purge) PURGE_TREE=true ;;
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

obm_begin_log "obm_phase2_rollback"

stop_zeek() {
    log_step "停止 Zeek..."
    if [[ ! -x "$ZEEKCTL" ]]; then
        log_info "找不到 ${ZEEKCTL}，略過停止。"
        return 0
    fi
    if [[ "$DRY_RUN_MODE" == true ]]; then
        log_info "[DRY-RUN] 若 zeekctl status 為 running，將執行 ${ZEEKCTL} stop"
        return 0
    fi
    local status
    status="$("$ZEEKCTL" status 2>/dev/null || true)"
    if [[ "$status" == *running* ]]; then
        "$ZEEKCTL" stop
        log_success "已停止 Zeek"
    else
        log_info "Zeek 目前不是 running，不呼叫 stop。"
    fi
}

restore_configs() {
    log_step "還原 Zeek 設定，並移除本專案的輪替檔..."
    obm_remove_marked_file "$CRON_FILE" "\[OBM Phase 2\]"
    obm_restore_or_remove_file "/etc/logrotate.d/zeek" "remove"
    obm_restore_or_remove_file "/opt/zeek/etc/node.cfg" "keep"
    obm_restore_or_remove_file "/opt/zeek/share/zeek/site/local.zeek" "keep"
    log_info "不變更登入殼層 PATH。"
}

purge_packages() {
    if [[ "$PURGE_PACKAGES" != true ]]; then
        return 0
    fi
    log_step "卸載 zeek 套件與 OBS 來源。保留 jq，不執行 autoremove。"
    if [[ "$DRY_RUN_MODE" == true ]]; then
        log_info "[DRY-RUN] 若 zeek 已安裝，將執行 apt-get purge -y zeek"
        log_info "[DRY-RUN] 將移除 ${ZEEK_LIST} 與 ${ZEEK_KEYRING}（若有 .bak_orig 則還原）"
        return 0
    fi

    export DEBIAN_FRONTEND=noninteractive
    export NEEDRESTART_MODE=a
    if dpkg-query -W -f='${Status}' zeek 2>/dev/null | grep -q "install ok installed"; then
        apt-get purge -y zeek
        log_success "已卸載 zeek 套件。jq 仍保留。"
    else
        log_info "zeek 套件目前未安裝。"
    fi
    obm_restore_or_remove_file "$ZEEK_LIST" "remove"
    obm_restore_or_remove_file "$ZEEK_KEYRING" "remove"
    apt-get update -y
}

purge_tree() {
    if [[ "$PURGE_TREE" != true ]]; then
        return 0
    fi
    log_step "刪除 /opt/zeek（含日誌）..."
    if [[ "$DRY_RUN_MODE" == true ]]; then
        log_info "[DRY-RUN] 將刪除目錄 /opt/zeek"
        return 0
    fi
    if [[ ! -d /opt/zeek ]]; then
        log_info "/opt/zeek 不存在，略過刪除。"
        return 0
    fi
    rm -rf /opt/zeek
    log_success "已刪除 /opt/zeek"
}

main() {
    echo -e "${BLUE}==================================================================${NC}"
    echo -e "${BLUE}   OpenRumble 第二階段：Zeek 一鍵回滾                  ${NC}"
    echo -e "${BLUE}   日誌檔案: ${PWD}/${LOG_FILE}                                  ${NC}"
    echo -e "${BLUE}==================================================================${NC}"

    obm_require_root
    obm_require_ubuntu_2404
    obm_acquire_lock "obm-runtime"

    if [[ "$DRY_RUN_MODE" == true ]]; then
        log_info "執行模式: [DRY-RUN] 不修改系統。"
    else
        echo -e "${YELLOW}資安警示：即將停止 Zeek 並還原第二階段設定。${NC}"
        if [[ "$PURGE_PACKAGES" == true ]]; then
            echo -e "${YELLOW}同時會卸載 zeek 套件與 OBS 來源。不會卸載 jq。${NC}"
        fi
        if [[ "$PURGE_TREE" == true ]]; then
            echo -e "${YELLOW}同時會刪除 /opt/zeek。裡面的日誌會一起消失。${NC}"
        fi
        if ! obm_confirm "確認要執行第二階段回滾嗎？"; then
            log_warn "使用者中止回滾作業。"
            exit 2
        fi
        if [[ "$PURGE_TREE" == true ]]; then
            if ! obm_confirm_phrase "即將刪除 /opt/zeek（含日誌）" "DELETE"; then
                log_warn "未通過刪除確認，中止。"
                exit 2
            fi
        fi
    fi

    stop_zeek
    restore_configs
    purge_packages
    purge_tree

    if [[ "$DRY_RUN_MODE" == true ]]; then
        echo -e "\n${GREEN}[SUCCESS] --dry-run 預檢完成。上面是預計還原與刪除的項目。${NC}"
    else
        echo -e "\n${GREEN}==================================================================${NC}"
        echo -e "${GREEN}[SUCCESS] 第二階段回滾完成。${NC}"
        echo -e "  - 詳細回滾日誌 : ${PWD}/${LOG_FILE}"
        echo -e "${GREEN}==================================================================${NC}"
    fi
}

main "$@"
