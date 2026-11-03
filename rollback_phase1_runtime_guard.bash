#!/bin/bash
# ==============================================================================
# Script Name   : rollback_phase1_runtime_guard.bash
# Description   : OpenRumble 第一階段：執行時期安全防護一鍵回滾
# Target Platform: Ubuntu 24.04 LTS (Noble Numbat)
# Author        : 資安防禦架構實驗室
# ==============================================================================
# Version History:
#   v1.0.0 (2026-11-03) - 初始版本。
#   v1.1.0 (2026-11-03) - set -euo pipefail、.bak_orig、對稱還原。
#   v1.2.0 (2026-11-03) - 改用 lib/obm_common.sh；支援 --yes；
#                         一併清除 /etc/sudoers.d/99-obm-audit-test-*。
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/obm_common.sh
source "$SCRIPT_DIR/lib/obm_common.sh"

DRY_RUN_MODE=false
YES_MODE=false
PURGE_PACKAGES=false

usage() {
    echo "使用方式: $0 [--dry-run] [--purge-packages] [--yes] [--help]"
    echo "  --dry-run           僅列出預計還原的備份與刪除檔案，不對主機進行修改"
    echo "  --purge-packages    進一步移除 falco 套件與官方軟體源（保留系統 auditd）"
    echo "  --yes               略過互動確認"
    echo "  --help, -h          顯示此說明訊息"
}

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN_MODE=true ;;
        --purge-packages) PURGE_PACKAGES=true ;;
        --yes) YES_MODE=true ;;
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

LOG_FILE="obm_phase1_rollback_$(date +%Y%m%d_%H%M%S).log"
obm_init_logging "$LOG_FILE"

cleanup_local_falco_rules() {
    local rules="/etc/falco/falco_rules.local.yaml"
    local begin="# [OBM Phase 1] BEGIN obm-sudoers"
    local end="# [OBM Phase 1] END obm-sudoers"
    obm_restore_or_remove_file "$rules" "keep"
    if [ ! -f "$rules" ]; then
        return 0
    fi
    if grep -Fxq "$begin" "$rules"; then
        if [ "$DRY_RUN_MODE" = true ]; then
            log_info "[DRY-RUN] 將自 ${rules} 移除 OBM 規則區塊"
            return 0
        fi
        local tmp
        tmp="$(mktemp)"
        awk -v b="$begin" -v e="$end" '
            $0 == b { skip = 1; next }
            skip && $0 == e { skip = 0; next }
            skip { next }
            { print }
        ' "$rules" > "$tmp"
        if ! grep -q '[^[:space:]]' "$tmp"; then
            rm -f "$tmp" "$rules"
            log_success "已移除只含 OBM 規則的 ${rules}"
            return 0
        fi
        cat "$tmp" > "$rules"
        rm -f "$tmp"
        log_success "已自 ${rules} 移除 OBM 規則區塊"
        return 0
    fi
    local content rule_count
    content="$(grep -v '^[[:space:]]*$' "$rules" || true)"
    rule_count="$(grep -c '^- rule:' "$rules" || true)"
    if [ "$content" = "# [OBM Phase 1] 自訂規則已改放 /etc/falco/rules.d/obm-sudoers.yaml" ] \
        || { [ "$rule_count" -le 1 ] && grep -q 'Detect Sudoers Modification' "$rules" && grep -q '\[OBM Phase 1\]' "$rules"; }; then
        if [ "$DRY_RUN_MODE" = true ]; then
            log_info "[DRY-RUN] 將移除只含 OBM 規則的 ${rules}"
        else
            rm -f "$rules"
            log_success "已移除只含 OBM 規則的 ${rules}"
        fi
    fi
}

rollback_falco_configs() {
    log_step "回滾 Falco 核心配置與自訂規則..."

    if systemctl is-active --quiet falco-modern-bpf 2>/dev/null || systemctl is-enabled --quiet falco-modern-bpf 2>/dev/null; then
        if [ "$DRY_RUN_MODE" = true ]; then
            log_info "[DRY-RUN] 將停止並停用服務: falco-modern-bpf"
        else
            systemctl stop falco-modern-bpf || true
            systemctl disable falco-modern-bpf >/dev/null 2>&1 || true
            log_info "已停止並停用 falco-modern-bpf 服務"
        fi
    fi

    obm_restore_or_remove_file "/etc/falco/config.d/99-file-output.yaml" "remove"
    obm_restore_or_remove_file "/etc/falco/rules.d/obm-sudoers.yaml" "remove"
    cleanup_local_falco_rules
    obm_restore_or_remove_file "/etc/falco/falco.yaml" "keep"
}

rollback_auditd_configs() {
    log_step "回滾 Auditd 規則與輪替設定..."
    obm_restore_or_remove_file "/etc/audit/rules.d/obm-identity.rules" "remove"
    obm_restore_or_remove_file "/etc/audit/auditd.conf" "keep"

    if [ "$DRY_RUN_MODE" = false ]; then
        augenrules --load >/dev/null 2>&1 || true
        service auditd reload >/dev/null 2>&1 || service auditd restart >/dev/null 2>&1 || systemctl restart auditd >/dev/null 2>&1 || true
        log_success "Auditd 已重設並重新載入核心規則"
    else
        log_info "[DRY-RUN] 將執行: augenrules --load 並重載 auditd 服務"
    fi
}

rollback_logrotate_and_artifacts() {
    log_step "清理日誌輪替設定與測試產物..."
    obm_restore_or_remove_file "/etc/logrotate.d/falco" "remove"

    local artifact
    local found_any=false
    shopt -s nullglob
    for artifact in /var/log/falco_events.json* /etc/sudoers.d/99-obm-audit-test-* /etc/sudoers.d/99-test-backdoor; do
        found_any=true
        if [ "$DRY_RUN_MODE" = true ]; then
            log_info "[DRY-RUN] 將清理測試與事件殘留檔: $artifact"
        else
            rm -f "$artifact"
            log_success "已清除殘留檔案: $artifact"
        fi
    done
    shopt -u nullglob

    if [ "$found_any" = false ]; then
        log_info "未發現殘留的測試事件日誌或後門檔案"
    fi
}

purge_system_packages() {
    if [ "$PURGE_PACKAGES" != true ]; then
        return 0
    fi
    log_step "進階清理：解除安裝 Falco 與相關 Repository..."
    if [ "$DRY_RUN_MODE" = true ]; then
        log_info "[DRY-RUN] 將移除套件: falco (保留系統核心 auditd)"
        log_info "[DRY-RUN] 將刪除軟體源與金鑰: /etc/apt/sources.list.d/falcosecurity.list, /usr/share/keyrings/falco-archive-keyring.gpg"
        return 0
    fi
    export DEBIAN_FRONTEND=noninteractive
    if dpkg -s falco >/dev/null 2>&1; then
        apt-get purge -y falco
        apt-get autoremove -y
    else
        log_info "falco 套件未安裝，略過卸載"
    fi
    rm -f /etc/apt/sources.list.d/falcosecurity.list
    rm -f /usr/share/keyrings/falco-archive-keyring.gpg
    apt-get update -y
    log_success "已徹底卸載 Falco 套件並清除 apt 軟體源與金鑰"
}

main() {
    obm_require_root
    obm_check_ubuntu_2404 warn
    obm_acquire_lock

    echo -e "${C_BLUE}==================================================================${C_RESET}"
    echo -e "${C_BLUE}   OpenRumble 第一階段：環境一鍵回滾 (Rollback) 程序    ${C_RESET}"
    echo -e "${C_BLUE}   日誌檔案: $PWD/$LOG_FILE                                      ${C_RESET}"
    echo -e "${C_BLUE}==================================================================${C_RESET}"

    if [ "$DRY_RUN_MODE" = true ]; then
        log_info "執行模式: [DRY-RUN 模擬預檢] (不修改系統狀態)"
    else
        echo -e "${C_YELLOW}資安警示：即將還原主機設定至部署前狀態，所有測試產生的日誌將被清除。${C_RESET}"
        if ! obm_confirm "確認要執行回滾程序嗎？ [y/N]: "; then
            log_warn "使用者中止回滾作業。"
            exit 0
        fi
    fi

    rollback_falco_configs
    rollback_auditd_configs
    rollback_logrotate_and_artifacts
    purge_system_packages

    if [ "$DRY_RUN_MODE" = true ]; then
        echo -e "\n${C_GREEN}[SUCCESS] --dry-run 預檢完成！上述為預計還原的動作與檔案清單。${C_RESET}"
    else
        echo -e "\n${C_GREEN}==================================================================${C_RESET}"
        echo -e "${C_GREEN}[SUCCESS] 主機環境回滾作業完成！${C_RESET}"
        echo -e "  - Falco 服務狀態 : $(systemctl is-active falco-modern-bpf 2>/dev/null || echo 'inactive')"
        echo -e "  - 稽核規則狀態   : 已恢復原生 auditd 規則清單"
        echo -e "  - 詳細回滾日誌   : $PWD/$LOG_FILE"
        echo -e "${C_GREEN}==================================================================${C_RESET}"
    fi
}

main "$@"
