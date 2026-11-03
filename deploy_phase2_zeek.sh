#!/bin/bash
# ==============================================================================
# Script Name   : deploy_phase2_zeek.sh
# Description   : OpenRumble 第二階段：Zeek 網路流量分析自動化部署
#                 JSON 日誌、zeekctl cron 輪替、歸檔日誌的 logrotate。
#                 不修改登入殼層 PATH，Zeek 一律使用 /opt/zeek/bin 絕對路徑。
# Target Platform: Ubuntu 24.04 LTS (Noble Numbat)
# Author        : 資安防禦架構實驗室
# ==============================================================================
# Version History:
#   v2.0.0 (2026-11-03) - 對齊第一階段的失敗即停、.bak_orig、--yes / --dry-run。
#                         APT 來源一次寫入 signed-by；gpg --dearmor --yes。
#                         印出金鑰指紋，不把未核對的指紋寫死。
#                         介面必須存在。zeekctl deploy 失敗即中止。
#                         成功訊息只在 zeekctl status 出現 running 之後印出。
#                         不安裝會改寫登入殼層 PATH 的設定。不安裝後卸載 jq。
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/obm_common.sh
source "${SCRIPT_DIR}/lib/obm_common.sh"

DRY_RUN_MODE=false
YES_MODE=false

ZEEK_KEY_URL="https://download.opensuse.org/repositories/security:/zeek/xUbuntu_24.04/Release.key"
ZEEK_LIST="/etc/apt/sources.list.d/security:zeek.list"
ZEEK_KEYRING="/usr/share/keyrings/security_zeek.gpg"
ZEEKCTL="/opt/zeek/bin/zeekctl"
NODE_CFG="/opt/zeek/etc/node.cfg"
LOCAL_ZEEK="/opt/zeek/share/zeek/site/local.zeek"
CRON_FILE="/etc/cron.d/obm-zeek"
LOGROTATE_FILE="/etc/logrotate.d/zeek"

usage() {
    cat <<'EOF'
使用方式: deploy_phase2_zeek.sh [--dry-run] [--yes]
  --dry-run   只做發行版、介面與套件源預檢，不修改系統
  --yes       略過互動確認（TUI 會先確認再帶這個旗標）
  --help, -h  顯示說明

離開碼: 0 完成，1 失敗，2 操作者中止。
EOF
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

obm_begin_log "obm_phase2_deploy"

# 只把介面名稱印到 stdout，方便呼叫端接住。錯誤走 stderr。
require_listen_iface() {
    local iface=""
    iface="$(ip route get 8.8.8.8 2>/dev/null | awk '{
        for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit }
    }' || true)"
    iface="${iface%%@*}"
    if [[ -z "$iface" ]]; then
        iface="$(ip -o link show 2>/dev/null | awk -F': ' '
            {
                split($2, a, "@")
                n = a[1]
                if (n !~ /^(lo|docker.*|veth.*|br-.*|virbr.*)$/) { print n; exit }
            }
        ' || true)"
    fi
    if [[ -z "$iface" || ! "$iface" =~ ^[A-Za-z0-9._:-]+$ ]]; then
        log_error "找不到可用的監聽介面。請確認 ip link 之後再部署。"
        exit 1
    fi
    if ! ip link show dev "$iface" >/dev/null 2>&1; then
        log_error "介面 ${iface} 不存在於 ip link，中止部署。"
        exit 1
    fi
    printf '%s\n' "$iface"
}

preview_zeek_key() {
    local tmp
    tmp="$(mktemp)"
    rm -f "$tmp"
    curl -fsSL "$ZEEK_KEY_URL" | gpg --dearmor --yes -o "$tmp"
    log_step "Zeek OBS 金鑰指紋（請自行與 OpenSUSE 公布值核對，腳本不寫死指紋）："
    gpg --batch --show-keys --keyid-format long "$tmp"
    rm -f "$tmp"
}

check_repo_reachable() {
    if ! command -v curl >/dev/null 2>&1; then
        log_error "缺少 curl，無法驗證 Zeek 套件源。"
        exit 1
    fi
    log_info "測試 Zeek OBS 套件源連線: ${ZEEK_KEY_URL}"
    local code=""
    code="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 8 -L -I "$ZEEK_KEY_URL" || true)"
    case "$code" in
        200|301|302|303|307|308)
            log_success "Zeek OBS 儲存庫連線正常 (HTTP ${code})"
            ;;
        *)
            log_error "無法連線至 Zeek 儲存庫 (HTTP ${code:-none})。"
            exit 1
            ;;
    esac
}

install_zeek_packages() {
    log_step "匯入 Zeek OBS 簽署金鑰與套件源..."
    install -d -m 0755 /usr/share/keyrings
    obm_safe_backup "$ZEEK_KEYRING"
    curl -fsSL "$ZEEK_KEY_URL" | gpg --batch --dearmor --yes -o "$ZEEK_KEYRING"
    chmod a+r "$ZEEK_KEYRING"
    log_step "Zeek OBS 金鑰指紋（請自行與 OpenSUSE 公布值核對，腳本不寫死指紋）："
    gpg --batch --show-keys --keyid-format long "$ZEEK_KEYRING"

    local source_line="deb [signed-by=${ZEEK_KEYRING}] http://download.opensuse.org/repositories/security:/zeek/xUbuntu_24.04/ /"
    obm_safe_backup "$ZEEK_LIST"
    printf '%s\n' "$source_line" > "$ZEEK_LIST"
    log_success "APT 來源已一次寫入 signed-by 那一行"

    export DEBIAN_FRONTEND=noninteractive
    export NEEDRESTART_MODE=a
    export APT_LISTCHANGES_FRONTEND=none
    apt-get update -y
    # jq 供日後查看 JSON 日誌。回滾與 --purge-packages 都不會卸載它。
    apt-get install -y \
        -o Dpkg::Options::=--force-confdef \
        -o Dpkg::Options::=--force-confold \
        zeek jq logrotate cron
    if [[ ! -x "$ZEEKCTL" ]]; then
        log_error "安裝後仍找不到 ${ZEEKCTL}。"
        exit 1
    fi
    log_success "Zeek 已安裝: $(/opt/zeek/bin/zeek --version)"
    log_info "Zeek 指令使用絕對路徑 ${ZEEKCTL}。本腳本不修改登入殼層 PATH。"
}

configure_zeek() {
    local iface="$1"
    log_step "寫入 node.cfg 與 JSON 日誌設定..."
    if [[ ! -f "$NODE_CFG" || ! -f "$LOCAL_ZEEK" ]]; then
        log_error "找不到 ${NODE_CFG} 或 ${LOCAL_ZEEK}。Zeek 套件布局與預期不符。"
        exit 1
    fi

    obm_safe_backup "$NODE_CFG"
    cat > "$NODE_CFG" <<EOF
# [OBM Phase 2] standalone listener
[zeek]
type=standalone
host=localhost
interface=${iface}
EOF

    obm_safe_backup "$LOCAL_ZEEK"
    if ! grep -q "\[OBM Phase 2\]" "$LOCAL_ZEEK"; then
        cat >> "$LOCAL_ZEEK" <<'EOF'

# [OBM Phase 2] 強制啟用結構化 JSON 輸出以利交叉關聯
@load policy/tuning/json-logs.zeek
redef LogAscii::use_json = T;
EOF
    fi
    log_success "已綁定介面 ${iface}，並啟用 JSON 日誌"
}

deploy_and_require_running() {
    log_step "執行 zeekctl deploy..."
    "$ZEEKCTL" deploy
    local status
    status="$("$ZEEKCTL" status 2>/dev/null || true)"
    if [[ "$status" != *running* ]]; then
        log_error "zeekctl status 未顯示 running，部署不算成功。"
        exit 1
    fi
    log_success "zeekctl status 已顯示 running"
}

install_log_rotation() {
    log_step "安裝 zeekctl cron，並只對歸檔日誌設定 logrotate..."
    obm_safe_backup "$CRON_FILE"
    cat > "$CRON_FILE" <<EOF
# [OBM Phase 2] Zeek 自己的日誌輪替。current 目錄交給 zeekctl，不在這裡處理。
SHELL=/bin/bash
PATH=/usr/sbin:/usr/bin:/sbin:/bin
*/5 * * * * root ${ZEEKCTL} cron
EOF
    chmod 0644 "$CRON_FILE"
    "$ZEEKCTL" cron
    log_success "已安裝 ${CRON_FILE}"

    obm_safe_backup "$LOGROTATE_FILE"
    cat > "$LOGROTATE_FILE" <<'EOF'
# [OBM Phase 2] 只輪替 zeekctl cron 歸檔後的日期目錄，不處理 current/。
/opt/zeek/logs/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/*.log {
    su root root
    daily
    rotate 5
    missingok
    notifempty
    compress
    delaycompress
    nocreate
}
EOF
    chmod 0644 "$LOGROTATE_FILE"
    local lr_out lr_rc
    lr_out="$(mktemp)"
    set +e
    logrotate -d "$LOGROTATE_FILE" >"$lr_out" 2>&1
    lr_rc=$?
    set -e
    if [[ "$lr_rc" -ne 0 ]]; then
        if grep -q 'error:' "$lr_out" && ! grep 'error:' "$lr_out" | grep -qv 'No such file or directory'; then
            log_warn "Logrotate 語法可接受；歸檔目錄尚不存在。"
        else
            cat "$lr_out" >&2
            rm -f "$lr_out"
            log_error "logrotate 預檢失敗。請執行 logrotate -d ${LOGROTATE_FILE} 查看原因。"
            exit 1
        fi
    fi
    rm -f "$lr_out"
    log_success "歸檔日誌的 logrotate 預檢通過"
}

main() {
    echo -e "${BLUE}==================================================================${NC}"
    echo -e "${BLUE}   OpenRumble 第二階段：Zeek 流量分析自動化部署        ${NC}"
    echo -e "${BLUE}   日誌檔案: ${PWD}/${LOG_FILE}                                  ${NC}"
    echo -e "${BLUE}==================================================================${NC}"

    obm_require_root
    obm_require_ubuntu_2404
    obm_acquire_lock "obm-runtime"

    if systemctl is-active --quiet falco-modern-bpf 2>/dev/null; then
        log_success "第一階段 Falco (Modern eBPF) 正常運作中"
    else
        log_warn "第一階段 Falco 服務未處於 active 狀態，交叉驗證可能受限。"
    fi

    local iface=""
    iface="$(require_listen_iface)"
    log_info "綁定外網監聽介面: ${iface}"

    if ! command -v curl >/dev/null 2>&1 || ! command -v gpg >/dev/null 2>&1; then
        log_warn "系統還沒有 curl 或 gpg。確認後會先安裝，再檢查套件源並印出金鑰指紋。"
    else
        check_repo_reachable
        preview_zeek_key
    fi

    if [[ "$DRY_RUN_MODE" == true ]]; then
        log_info "[DRY-RUN] 將安裝 zeek、jq、logrotate 與 cron（若尚未安裝）。不會卸載 jq。"
        log_info "[DRY-RUN] 將把帶 signed-by 的來源寫入 ${ZEEK_LIST}"
        log_info "[DRY-RUN] 將印出金鑰指紋，不會把指紋寫死在腳本裡。"
        log_info "[DRY-RUN] 將寫入 ${NODE_CFG}（interface=${iface}）與 ${LOCAL_ZEEK} 的 JSON 區塊。"
        log_info "[DRY-RUN] 將執行 ${ZEEKCTL} deploy，並在 status 出現 running 後才算成功。"
        log_info "[DRY-RUN] 將安裝 ${CRON_FILE}（${ZEEKCTL} cron）與只涵蓋歸檔目錄的 ${LOGROTATE_FILE}。"
        log_info "[DRY-RUN] 不會修改登入殼層 PATH。"
        echo -e "\n${GREEN}[SUCCESS] --dry-run 預檢完成。環境支援第二階段，未修改系統檔案。${NC}"
        exit 0
    fi

    if ! obm_confirm "即將安裝或設定 Zeek（以及缺少時的 jq）。是否繼續？"; then
        log_warn "使用者中止操作。"
        exit 2
    fi

    if ! command -v curl >/dev/null 2>&1 || ! command -v gpg >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y
        apt-get install -y curl gnupg ca-certificates
        check_repo_reachable
    fi

    install_zeek_packages
    configure_zeek "$iface"
    deploy_and_require_running
    install_log_rotation

    echo -e "\n${GREEN}==================================================================${NC}"
    echo -e "${GREEN}[SUCCESS] 第二階段 Zeek 部署完成，zeekctl status 為 running。${NC}"
    echo -e "  - 控制程式     : ${ZEEKCTL}"
    echo -e "  - 監聽介面     : ${iface}"
    echo -e "  - 日誌目錄     : /opt/zeek/logs/current/ (JSON)"
    echo -e "  - 輪替         : ${CRON_FILE} 與歸檔目錄的 logrotate"
    echo -e "  - 詳細部署日誌 : ${PWD}/${LOG_FILE}"
    echo -e "${GREEN}==================================================================${NC}"
}

main "$@"
