#!/bin/bash
# ==============================================================================
# Script Name   : scripts/phase1/deploy_phase1_runtime_guard.sh
# Description   : OpenRumble 第一階段：主機執行時期防護矩陣自動化部署腳本
#                 (Falco Modern eBPF + Audit Log + Logrotate)
# Target Platform: Ubuntu 24.04 LTS (Noble Numbat)
# Author        : 資安防禦架構實驗室
# ==============================================================================
# Version History (版本變更紀錄):
#   v1.0.0 (2026-11-03) - 初始版本：整合 Falco eBPF 與 auditd 雙軌部署。
#   v1.1.0 (2026-11-03) - 修正 Falco 0.45.2 規則語法。
#   v1.2.0 (2026-11-03) - 導入 config.d 覆蓋機制。
#   v1.3.0 (2026-11-03) - 發行版校驗、日誌、備份、--dry-run。
#   v1.4.0 (2026-11-03) - set -euo pipefail、.bak_orig、規則與 auditd 容錯。
#   v1.5.0 (2026-11-03) - 改用 lib/obm_common.sh；Falco 規則改放 rules.d 或
#                         附加標記區塊，不再覆寫既有 falco_rules.local.yaml；
#                         支援 --yes。
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=../../lib/obm_common.sh
source "${REPO_ROOT}/lib/obm_common.sh"

DRY_RUN_MODE=false
YES_MODE=false

usage() {
    echo "使用方式: $0 [--dry-run] [--yes] [--help]"
    echo "  --dry-run   僅執行相依性與環境預檢，不修改任何系統檔案與安裝套件"
    echo "  --yes       略過互動確認"
    echo "  --help, -h  顯示此說明訊息"
}

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN_MODE=true ;;
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

LOG_FILE="obm_phase1_deploy_$(date +%Y%m%d_%H%M%S).log"
obm_init_logging "$LOG_FILE"

check_system_compatibility() {
    log_step "驗證系統發行版與核心相容性..."
    obm_require_root
    obm_check_ubuntu_2404 strict

    if [ ! -r /sys/kernel/btf/vmlinux ]; then
        log_error "未偵測到 /sys/kernel/btf/vmlinux！核心缺乏 BTF 支援，無法原生啟動 Modern eBPF。"
        exit 1
    fi
    local btf_size
    btf_size=$(stat -c%s /sys/kernel/btf/vmlinux 2>/dev/null || echo 0)
    log_success "核心 BTF 支援確認正常 (大小: ${btf_size} bytes)"

    log_info "測試關鍵套件庫存取 (falco.org)..."
    if ! curl -fsSI --connect-timeout 5 https://download.falco.org > /dev/null 2>&1; then
        log_error "無法連線至 https://download.falco.org，請檢查外網與防火牆白名單。"
        exit 1
    fi
    log_success "網路連線預檢通過"
}

review_dependencies() {
    log_step "檢查相依軟體服務..."
    local missing_pkgs=()

    command -v auditd >/dev/null 2>&1 || missing_pkgs+=("auditd")
    command -v auditctl >/dev/null 2>&1 || missing_pkgs+=("audispd-plugins")
    command -v falco >/dev/null 2>&1 || missing_pkgs+=("falco")
    command -v logrotate >/dev/null 2>&1 || missing_pkgs+=("logrotate")
    command -v gpg >/dev/null 2>&1 || missing_pkgs+=("gpg")

    if [ ${#missing_pkgs[@]} -eq 0 ]; then
        log_success "所有相依軟體與工具均已就緒"
        return 0
    fi

    log_warn "系統尚未安裝以下相依套件: ${missing_pkgs[*]}"
    if [ "$DRY_RUN_MODE" = true ]; then
        log_info "[DRY-RUN] 預檢模式結束：實際執行時系統將提示安裝上述套件。"
        return 0
    fi

    if ! obm_confirm "資安提示：系統即將透過 apt 安裝上述缺失套件，是否繼續？ [y/N]: "; then
        log_warn "使用者取消變更，腳本安全退出。"
        exit 0
    fi

    log_step "更新套件索引並安裝基礎相依軟體..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y auditd audispd-plugins logrotate gpg ca-certificates curl

    if ! command -v falco >/dev/null 2>&1; then
        log_step "配置 Falco 官方專屬儲存庫..."
        install -d -m 0755 /usr/share/keyrings
        curl -fsSL https://falco.org/repo/falcosecurity-packages.asc | gpg --dearmor --yes -o /usr/share/keyrings/falco-archive-keyring.gpg
        chmod a+r /usr/share/keyrings/falco-archive-keyring.gpg
        echo "deb [signed-by=/usr/share/keyrings/falco-archive-keyring.gpg] https://download.falco.org/packages/deb stable main" > /etc/apt/sources.list.d/falcosecurity.list
        apt-get update -y
        apt-get install -y falco
    fi
}

set_auditd_conf_kv() {
    local conf_file="$1"
    local key="$2"
    local val="$3"
    if grep -Eq "^[[:space:]]*#?[[:space:]]*${key}[[:space:]]*=" "$conf_file"; then
        sed -i -E "s|^[[:space:]]*#?[[:space:]]*${key}[[:space:]]*=.*|${key} = ${val}|" "$conf_file"
    else
        echo "${key} = ${val}" >> "$conf_file"
    fi
}

configure_auditd() {
    log_step "配置 Auditd 身份鑑識規則與硬碟防爆設定..."

    local auditd_conf="/etc/audit/auditd.conf"
    if [ ! -f "$auditd_conf" ]; then
        log_error "找不到 $auditd_conf，請確認 auditd 套件安裝狀態。"
        exit 1
    fi
    obm_safe_backup "$auditd_conf"
    set_auditd_conf_kv "$auditd_conf" "max_log_file" "50"
    set_auditd_conf_kv "$auditd_conf" "max_log_file_action" "ROTATE"
    set_auditd_conf_kv "$auditd_conf" "num_logs" "5"
    set_auditd_conf_kv "$auditd_conf" "space_left_action" "SYSLOG"

    mkdir -p /etc/audit/rules.d
    local audit_rule_file="/etc/audit/rules.d/obm-identity.rules"
    obm_safe_backup "$audit_rule_file"
    cat <<'EOF' > "$audit_rule_file"
# [OBM Phase 1] 帳號異動與提權審計規則
-w /etc/sudoers -p wa -k identity_changes
-w /etc/sudoers.d/ -p wa -k identity_changes
-w /etc/passwd -p wa -k identity_changes
-w /etc/shadow -p wa -k identity_changes
-a always,exit -F arch=b64 -S setuid,setgid,setreuid,setregid,setresuid,setresgid -F auid>=1000 -F auid!=unset -k priv_escalation
-a always,exit -F arch=b32 -S setuid,setgid,setreuid,setregid,setresuid,setresgid -F auid>=1000 -F auid!=unset -k priv_escalation
EOF
    chmod 0640 "$audit_rule_file"

    augenrules --load
    service auditd reload >/dev/null 2>&1 || service auditd restart >/dev/null 2>&1 || systemctl restart auditd

    local loaded_rules
    loaded_rules="$(auditctl -l 2>/dev/null || true)"
    if [[ "$loaded_rules" != *identity_changes* ]]; then
        log_error "Auditd 規則驗證失敗：核心未成功載入 identity_changes 規則！"
        exit 1
    fi
    log_success "Auditd 配置與規則載入完成並通過核心檢核"
}

write_falco_rule_block() {
    local block="$1"
    cat <<'EOF' > "$block"
# [OBM Phase 1] BEGIN obm-sudoers
# [OBM Phase 1] 自訂高風險提權與 Sudoers 竄改偵測規則
- rule: Detect Sudoers Modification
  desc: 偵測到有人企圖修改、覆寫或連結 sudoers 設定檔以進行提權或植入後門
  condition: >
    (
      (
        open_write
        and (fd.name = /etc/sudoers or fd.name startswith /etc/sudoers.d/)
      )
      or (
        evt.type in (rename, renameat, renameat2, link, linkat, symlink, symlinkat)
        and (
          evt.arg.newpath = /etc/sudoers
          or evt.arg.newpath startswith /etc/sudoers.d/
          or evt.arg.target = /etc/sudoers
          or evt.arg.target startswith /etc/sudoers.d/
        )
      )
    )
    and not proc.exepath in (/usr/sbin/visudo, /usr/bin/apt, /usr/bin/apt-get, /usr/bin/dpkg)
  output: >
    [CRITICAL] 偵測到 Sudoers 修改行為！
    (使用者=%user.name 執行檔=%proc.exepath 指令=%proc.cmdline 事件=%evt.type 檔案=%fd.name 目標路徑=%evt.arg.newpath PID=%proc.pid)
  priority: CRITICAL
  tags: [security, privilege_escalation, obm_phase1]
# [OBM Phase 1] END obm-sudoers
EOF
}

retire_legacy_local_rule() {
    local dest="/etc/falco/falco_rules.local.yaml"
    if [ ! -f "$dest" ] || ! grep -q "rule: Detect Sudoers Modification" "$dest"; then
        return 0
    fi
    local rule_count
    rule_count=$(grep -cE "^[[:space:]]*- rule:" "$dest" || true)
    if [ "$rule_count" -gt 1 ]; then
        log_warn "falco_rules.local.yaml 同時含 OBM 規則與其他規則。rules.d 已寫入同名規則，請避免重複載入。"
        return 0
    fi
    obm_safe_backup "$dest"
    printf '%s\n' "# [OBM Phase 1] 自訂規則已改放 /etc/falco/rules.d/obm-sudoers.yaml" > "$dest"
    chmod 0640 "$dest"
    log_info "已將舊的整檔覆寫規則移出 falco_rules.local.yaml"
}

install_falco_rule() {
    local block begin end
    block="$(mktemp)"
    begin="# [OBM Phase 1] BEGIN obm-sudoers"
    end="# [OBM Phase 1] END obm-sudoers"
    write_falco_rule_block "$block"

    if [ -f /etc/falco/falco.yaml ] && grep -q '/etc/falco/rules\.d' /etc/falco/falco.yaml; then
        mkdir -p /etc/falco/rules.d
        local dest="/etc/falco/rules.d/obm-sudoers.yaml"
        obm_safe_backup "$dest"
        cat "$block" > "$dest"
        chmod 0640 "$dest"
        log_success "Falco 規則已寫入 $dest"
        retire_legacy_local_rule
    else
        local dest="/etc/falco/falco_rules.local.yaml"
        log_warn "falco.yaml 未載入 /etc/falco/rules.d，改為附加標記區塊至 $dest"
        obm_safe_backup "$dest"
        if [ -f "$dest" ] && ! grep -Fxq "$begin" "$dest" && grep -q "rule: Detect Sudoers Modification" "$dest"; then
            local rule_count
            rule_count=$(grep -cE "^[[:space:]]*- rule:" "$dest" || true)
            if [ "$rule_count" -le 1 ]; then
                cat "$block" > "$dest"
                chmod 0640 "$dest"
                rm -f "$block"
                log_success "已以標記區塊取代先前整檔寫入的 OBM 規則"
                return 0
            fi
        fi
        obm_upsert_marked_block "$dest" "$begin" "$end" "$block"
        chmod 0640 "$dest"
        log_success "已附加 OBM 規則區塊至 $dest"
    fi
    rm -f "$block"
}

configure_falco() {
    log_step "配置 Falco Modern eBPF 探針與告警管道..."

    mkdir -p /etc/falco/config.d
    local falco_output_override="/etc/falco/config.d/99-file-output.yaml"
    obm_safe_backup "$falco_output_override"
    cat <<'EOF' > "$falco_output_override"
# [OBM Phase 1] 強制將告警結構化輸出至本地檔案
json_output: true
file_output:
  enabled: true
  keep_alive: false
  filename: /var/log/falco_events.json
EOF

    install_falco_rule

    log_info "執行 Falco 規則與設定檔靜態校驗 (falco --dry-run)..."
    local falco_check_tmp
    falco_check_tmp=$(mktemp)
    if ! falco --dry-run > "$falco_check_tmp" 2>&1; then
        log_error "Falco 設定檔校驗失敗！錯誤詳情如下："
        cat "$falco_check_tmp"
        rm -f "$falco_check_tmp"
        exit 1
    fi
    rm -f "$falco_check_tmp"
    log_success "Falco 靜態語法校驗 (Dry-run) 通過"

    systemctl stop falco-kmod.service falco-bpf.service >/dev/null 2>&1 || true
    systemctl disable falco-kmod.service falco-bpf.service >/dev/null 2>&1 || true

    systemctl enable falco-modern-bpf >/dev/null 2>&1
    systemctl restart falco-modern-bpf

    if ! systemctl is-active --quiet falco-modern-bpf; then
        log_error "falco-modern-bpf 服務啟動失敗，請執行 journalctl -u falco-modern-bpf 檢查原因。"
        exit 1
    fi
    log_success "Falco Modern eBPF 服務已上線運行"
}

configure_logrotate() {
    log_step "配置 Falco 事件日誌輪替機制..."

    local log_owner log_group
    log_owner=$(stat -c "%U" /var/log)
    log_group=$(stat -c "%G" /var/log)

    local logrotate_file="/etc/logrotate.d/falco"
    obm_safe_backup "$logrotate_file"
    cat <<EOF > "$logrotate_file"
# [OBM Phase 1] Falco JSON 日誌輪替設定
/var/log/falco_events.json {
    su ${log_owner} ${log_group}
    daily
    rotate 7
    missingok
    notifempty
    compress
    copytruncate
}
EOF
    chmod 0644 "$logrotate_file"

    if ! logrotate -d "$logrotate_file" >/dev/null 2>&1; then
        log_error "Logrotate 設定檔驗證失敗，請執行 logrotate -d $logrotate_file 檢查。"
        exit 1
    fi
    log_success "Logrotate 配置通過安全性與語法驗證 (su ${log_owner} ${log_group})"
}

main() {
    echo -e "${C_BLUE}==================================================================${C_RESET}"
    echo -e "${C_BLUE}   OpenRumble 第一階段：執行時期安全防護部署手冊        ${C_RESET}"
    echo -e "${C_BLUE}   日誌檔案: $PWD/$LOG_FILE                                      ${C_RESET}"
    echo -e "${C_BLUE}==================================================================${C_RESET}"

    check_system_compatibility
    obm_acquire_lock
    review_dependencies

    if [ "$DRY_RUN_MODE" = true ]; then
        echo -e "\n${C_GREEN}[SUCCESS] --dry-run 預檢完成！環境完全支援第一階段部署，未異動任何系統檔案。${C_RESET}"
        exit 0
    fi

    configure_auditd
    configure_falco
    configure_logrotate

    if ! systemctl is-active --quiet falco-modern-bpf || ! systemctl is-active --quiet auditd; then
        log_error "服務未處於 active，部署未完成。"
        exit 1
    fi

    echo -e "\n${C_GREEN}==================================================================${C_RESET}"
    echo -e "${C_GREEN}[SUCCESS] 第一階段防護部署全數完成！${C_RESET}"
    echo -e "  - Falco 服務狀態 : $(systemctl is-active falco-modern-bpf 2>/dev/null || echo inactive)"
    echo -e "  - Auditd 服務狀態: $(systemctl is-active auditd 2>/dev/null || echo inactive)"
    echo -e "  - 詳細部署日誌   : $PWD/$LOG_FILE"
    echo -e "${C_GREEN}==================================================================${C_RESET}"
}

main "$@"
