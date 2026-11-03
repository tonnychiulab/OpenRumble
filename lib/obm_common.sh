#!/bin/bash
# ==============================================================================
# Script Name   : lib/obm_common.sh
# Description   : OpenRumble 共用函式：日誌、錯誤即停、備份還原、確認、flock、
#                 root 與 Ubuntu 24.04 檢查。由各階段腳本 source，不要直接執行。
# Target Platform: Ubuntu 24.04 LTS
# ==============================================================================

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    echo "這是函式庫，請由 OpenRumble 腳本 source，不要直接執行。" >&2
    exit 1
fi

ESC='\033'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
C_RED="$RED"
C_GREEN="$GREEN"
C_YELLOW="$YELLOW"
C_BLUE="$BLUE"
C_RESET="$NC"

log_info()    { echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')] [INFO] $1${NC}"; }
log_step()    { echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] [STEP] $1${NC}"; }
log_success() { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] [PASS] $1${NC}"; }
log_warn()    { echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] [WARN] $1${NC}"; }
log_error()   { echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] [FAIL] 錯誤: $1${NC}" >&2; }

# 失敗行同時寫到終端與日誌檔。obm_init_logging 把 stdout/stderr 接到 tee，
# shell 結束時 tee 會被訊號打斷，最後一行常常來不及出現在畫面上。
obm_show_failure() {
    local msg="$1"
    local line
    line="[$(date +'%Y-%m-%d %H:%M:%S')] [FAIL] 錯誤: ${msg}"
    if [[ -w /dev/tty ]]; then
        printf '%s\n' "$line" > /dev/tty || true
    else
        printf '%s\n' "$line" >&2 || true
    fi
    if [[ -n "${LOG_FILE:-}" ]]; then
        printf '%s\n' "$line" >> "${LOG_FILE}" || true
    fi
}

# ERR trap 展開時，$1 是失敗行、$2 是失敗指令。離開碼 0 會改記為 1，避免假成功。
obm_on_error() {
    local exit_code=$?
    local line_no="$1"
    local failed_cmd="$2"
    trap - ERR
    if [[ "$exit_code" -eq 0 ]]; then
        exit_code=1
    fi
    obm_show_failure "腳本於第 ${line_no} 行異常中止 (Exit Code: ${exit_code})，失敗指令: ${failed_cmd}"
    if [[ -n "${LOG_FILE:-}" ]]; then
        obm_show_failure "請檢視日誌: ${PWD}/${LOG_FILE}"
    fi
    exit "$exit_code"
}

# 參數解析完成後才開日誌，避免 --help 留下空白紀錄。
obm_begin_log() {
    local prefix="$1"
    LOG_FILE="${prefix}_$(date +%Y%m%d_%H%M%S).log"
    touch "$LOG_FILE"
    exec > >(tee -a "$LOG_FILE") 2>&1
    trap 'obm_on_error $LINENO "$BASH_COMMAND"' ERR
}

obm_init_logging() {
    LOG_FILE="$1"
    touch "$LOG_FILE"
    exec > >(tee -a "$LOG_FILE") 2>&1
    trap 'obm_on_error $LINENO "$BASH_COMMAND"' ERR
}

obm_require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        log_error "此腳本必須以 root 身分或 sudo 執行。"
        exit 1
    fi
}

# mode: strict（預設）不符合就結束；warn 只警告。
obm_check_ubuntu_2404() {
    local mode="${1:-strict}"
    if [[ ! -f /etc/os-release ]]; then
        log_error "找不到 /etc/os-release，無法判定作業系統。"
        exit 1
    fi
    # shellcheck disable=SC1091
    source /etc/os-release
    if [[ "${ID:-}" != "ubuntu" || "${VERSION_ID:-}" != "24.04" ]]; then
        if [[ "$mode" == "warn" ]]; then
            log_warn "非 Ubuntu 24.04 環境 (${NAME:-Unknown} ${VERSION_ID:-Unknown})，請確認路徑相容性。"
            return 0
        fi
        log_error "本工具基準為 Ubuntu 24.04 LTS。當前為: ${NAME:-Unknown} ${VERSION_ID:-Unknown}"
        exit 1
    fi
    log_success "發行版符合標準: ${NAME:-Ubuntu} (${VERSION_ID})"
}

obm_require_ubuntu_2404() {
    obm_check_ubuntu_2404 "${1:-strict}"
}

# 回傳 0 表示同意。YES_MODE=true 時略過提問（TUI 已先確認）。
obm_confirm() {
    local prompt="$1"
    if [[ "${YES_MODE:-false}" == true ]]; then
        log_info "已指定 --yes，略過確認：${prompt}"
        return 0
    fi
    if [[ "$prompt" != *"[y/N]"* ]]; then
        prompt="${prompt} [y/N]: "
    fi
    local answer=""
    read -r -p "$prompt" answer
    [[ "${answer}" =~ ^[yY]$ ]]
}

# 破壞性刪除用的字句確認。YES_MODE=true 時略過，呼叫端必須已經問過。
obm_confirm_phrase() {
    local prompt="$1"
    local phrase="$2"
    if [[ "${YES_MODE:-false}" == true ]]; then
        log_info "已指定 --yes，略過字句確認：${prompt}"
        return 0
    fi
    local answer=""
    read -r -p "${prompt}（請輸入 ${phrase}）: " answer
    [[ "${answer}" == "${phrase}" ]]
}

# 未給名稱時使用 obm-runtime，讓部署與回滾共用同一把鎖。佔用 fd 9。
obm_acquire_lock() {
    local name="${1:-obm-runtime}"
    local dir="/run/lock"
    if [[ ! -d "$dir" ]]; then
        dir="/var/lock"
    fi
    if ! command -v flock >/dev/null 2>&1; then
        log_error "找不到 flock，無法避免同時執行兩次部署或回滾。"
        exit 1
    fi
    mkdir -p "$dir"
    local path="${dir}/${name}.lock"
    exec 9>"$path"
    if ! flock -n 9; then
        log_error "已有另一個 OpenRumble 作業持有鎖: ${path}"
        exit 1
    fi
    log_info "已取得作業鎖: ${path}"
}

# 首次看到的非 OBM 內容寫入 .bak_orig，之後每次仍留時間戳備份。
obm_safe_backup() {
    local target_file="$1"
    if [[ ! -f "$target_file" ]]; then
        return 0
    fi
    local timestamp backup_path orig_backup_path
    timestamp="$(date +%Y%m%d_%H%M%S)"
    backup_path="${target_file}.bak_${timestamp}"
    orig_backup_path="${target_file}.bak_orig"
    log_info "依據資安政策進行備份: ${target_file} -> ${backup_path}"
    if [[ "${DRY_RUN_MODE:-false}" == true ]]; then
        return 0
    fi
    if [[ ! -f "$orig_backup_path" ]] && ! grep -a -q "\[OBM Phase" "$target_file" 2>/dev/null; then
        cp -p "$target_file" "$orig_backup_path"
    fi
    cp -p "$target_file" "$backup_path"
}

safe_backup() {
    obm_safe_backup "$@"
}

# 優先還原 .bak_orig，否則用最早一份不含 [OBM Phase 的備份。沒有備份時依 fallback 刪除或保留。
obm_restore_or_remove_file() {
    local target_file="$1"
    local fallback_mode="${2:-remove}"
    local chosen_backup=""

    if [[ -f "${target_file}.bak_orig" ]]; then
        chosen_backup="${target_file}.bak_orig"
    else
        local candidate
        while IFS= read -r candidate; do
            [[ -z "$candidate" ]] && continue
            if [[ -f "$candidate" ]] && ! grep -a -q "\[OBM Phase" "$candidate" 2>/dev/null; then
                chosen_backup="$candidate"
                break
            fi
        done < <(ls -tr "${target_file}.bak_"* 2>/dev/null || true)
    fi

    if [[ -n "$chosen_backup" && -f "$chosen_backup" ]]; then
        if [[ "${DRY_RUN_MODE:-false}" == true ]]; then
            log_info "[DRY-RUN] 將還原: ${chosen_backup} -> ${target_file}，並清理 ${target_file}.bak_*"
        else
            log_info "還原原生備份: ${chosen_backup} -> ${target_file}"
            cp -p "$chosen_backup" "$target_file"
            rm -f "${target_file}.bak_"*
            log_success "已復原設定: ${target_file}"
        fi
        return 0
    fi

    if [[ "$fallback_mode" == "remove" ]]; then
        if [[ -f "$target_file" ]] || compgen -G "${target_file}.bak_*" > /dev/null; then
            if [[ "${DRY_RUN_MODE:-false}" == true ]]; then
                log_info "[DRY-RUN] 將移除: ${target_file}"
            else
                rm -f "$target_file" "${target_file}.bak_"*
                log_success "已移除新增設定檔: ${target_file}"
            fi
        fi
    else
        log_warn "未找到 ${target_file} 備份檔，保留當前檔案。"
    fi
}

# 只刪除含指定標記、且由本專案寫入的檔案。
obm_remove_marked_file() {
    local target_file="$1"
    local marker="$2"
    if [[ ! -f "$target_file" ]]; then
        return 0
    fi
    if ! grep -a -q "$marker" "$target_file" 2>/dev/null; then
        log_warn "略過不含標記的檔案: ${target_file}"
        return 0
    fi
    if [[ "${DRY_RUN_MODE:-false}" == true ]]; then
        log_info "[DRY-RUN] 將移除標記檔: ${target_file}"
    else
        rm -f "$target_file"
        log_success "已移除標記檔: ${target_file}"
    fi
}

# block_file 須含 begin_line 與 end_line 兩整行。沒有標記就附加。
obm_upsert_marked_block() {
    local target="$1"
    local begin_line="$2"
    local end_line="$3"
    local block_file="$4"
    local tmp
    tmp="$(mktemp)"

    if [[ ! -f "$target" || ! -s "$target" ]]; then
        cat "$block_file" > "$tmp"
    elif grep -Fxq "$begin_line" "$target"; then
        awk -v begin="$begin_line" -v end="$end_line" -v block="$block_file" '
            $0 == begin {
                while ((getline line < block) > 0) print line
                close(block)
                skip = 1
                next
            }
            skip && $0 == end { skip = 0; next }
            skip { next }
            { print }
        ' "$target" > "$tmp"
    else
        cat "$target" > "$tmp"
        printf '\n' >> "$tmp"
        cat "$block_file" >> "$tmp"
    fi

    if [[ "${DRY_RUN_MODE:-false}" == true ]]; then
        rm -f "$tmp"
        log_info "[DRY-RUN] 將更新標記區塊: ${target}"
        return 0
    fi
    cat "$tmp" > "$target"
    rm -f "$tmp"
}

obm_gpg_fingerprint() {
    local key_file="$1"
    local output
    output=$(gpg --show-keys --with-colons "$key_file" 2>/dev/null || true)
    awk -F: '$1 == "fpr" { print $10; exit }' <<< "$output"
}

obm_show_gpg_fingerprint() {
    local key_file="$1"
    local fpr
    fpr="$(obm_gpg_fingerprint "$key_file")"
    if [[ -z "$fpr" ]]; then
        log_warn "無法讀取金鑰指紋: ${key_file}"
        return 0
    fi
    log_info "金鑰指紋: ${fpr}"
}

obm_logrotate_check() {
    local file="$1"
    local fatal="${2:-true}"
    if logrotate -d "$file" >/dev/null 2>&1; then
        return 0
    fi
    log_error "Logrotate 設定檔驗證失敗，請執行 logrotate -d ${file} 檢查。"
    if [[ "$fatal" == true ]]; then
        exit 1
    fi
    return 1
}
