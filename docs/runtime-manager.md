# 執行時期部署

Ubuntu 24.04 LTS。需要 root。先完成第一階段，再進行第二階段。

主控台只負責選單與離開碼。部署、回滾、複查都在獨立腳本裡，失敗會中止，不會印出成功。

```bash
sudo bash openrumble.sh
```

## 第一階段（Falco Modern eBPF、auditd、logrotate）

```bash
sudo bash deploy_phase1_runtime_guard.bash --dry-run
sudo bash deploy_phase1_runtime_guard.bash --yes
sudo bash verify_phase1_runtime_guard.sh
sudo bash rollback_phase1_runtime_guard.bash --dry-run
sudo bash rollback_phase1_runtime_guard.bash --yes
sudo bash rollback_phase1_runtime_guard.bash --yes --purge-packages
```

`--purge-packages` 只移除 falco 與它的軟體源，保留 auditd。

Falco 規則寫入 `/etc/falco/rules.d/obm-sudoers.yaml`。若這版 Falco 沒有載入 `rules.d`，則把標記區塊附加到 `falco_rules.local.yaml`，不整檔覆寫。

複查會短暫寫入 `/etc/sudoers.d/99-obm-audit-test-*`，內容只有註解。程序結束或被中斷時會刪除。回滾也會清掉這個檔名。

## 第二階段（Zeek JSON 日誌）

```bash
sudo bash deploy_phase2_zeek.sh --dry-run
sudo bash deploy_phase2_zeek.sh --yes
sudo bash verify_phase2_zeek.sh
sudo bash rollback_phase2_zeek.sh --dry-run
sudo bash rollback_phase2_zeek.sh --yes
sudo bash rollback_phase2_zeek.sh --dry-run --purge-packages --purge
sudo bash rollback_phase2_zeek.sh --purge-packages --purge
```

部署使用 `/opt/zeek/bin` 的絕對路徑，不修改 `/etc/profile`。APT 來源一次寫成帶 `signed-by` 的項目，並在安裝前印出金鑰指紋。`zeekctl deploy` 失敗，或結束時不是 `running`，腳本會中止。

日誌輪替交給 `zeekctl cron`（`/etc/cron.d/obm-zeek`）。logrotate 只壓縮已歸檔目錄，不對 `current/` 使用 copytruncate。

`--purge-packages` 只卸載 zeek、移除 OBS 來源與金鑰，不卸載 jq。要連 `/opt/zeek` 一起刪掉才加 `--purge`。未加 `--yes` 時，刪除前要再輸入 `DELETE`。加上 `--yes` 會略過這次確認。

`verify_phase2_zeek.sh` 只讀檢查，不改系統、不抓封包。介面還沒有流量時，目前日誌的 JSON 檢查可能失敗。

### 第二階段互動式 TUI

主控台的 6、7、8、9、10 會開啟這套 Zeek 主控台，而不是在選單裡直接部署。也可以單獨啟動：

```bash
cd phase2-tui
npm install
npm run build
cd ..
sudo bash phase2-tui/obm-zeek-tui.sh
sudo bash phase2-tui/obm-zeek-tui.sh --select deploy
```

需要 Node.js 18 以上。`phase2-tui/dist/main.js` 建好之後，目標主機不必再裝 npm。

畫面比照 [oh-my-pi](https://github.com/can1357/oh-my-pi) 的 TUI：上方狀態、方向鍵選單、Enter 前先確認、執行中即時輸出、Esc 取消。oh-my-pi 的渲染器是 Bun 上的 `@oh-my-pi/pi-tui`，入口使用 `bun:ffi`，所以這裡用 TypeScript 做出同一套操作，再交給下面這些腳本：

| 選單 | 確認後執行 |
| --- | --- |
| 正式部署 | `deploy_phase2_zeek.sh --yes` |
| Dry-run | `deploy_phase2_zeek.sh --dry-run` |
| 唯讀複查 | `verify_phase2_zeek.sh` |
| 看日誌 | 只 `tail` `/opt/zeek/logs/current/*.log` |
| 還原設定 | `rollback_phase2_zeek.sh --yes` |
| 卸載 zeek 套件 | `rollback_phase2_zeek.sh --yes --purge-packages`（不卸載 jq，不刪 `/opt/zeek`） |
| 刪除 `/opt/zeek` | 先輸入 `DELETE`，再執行 `rollback_phase2_zeek.sh --yes --purge` |

TUI 不重寫 apt 或 zeekctl。離開碼 0 是腳本完成，2 是操作者在腳本裡中止，其他是失敗。

## Ubuntu 驗收

1. 第一階段 `--dry-run`、部署、複查、回滾都跑過，離開碼與畫面上的成功或失敗一致。
2. 複查執行中按 Ctrl+C，確認 `/etc/sudoers.d/99-obm-audit-test-*` 不留在系統上。
3. 第二階段 `--dry-run`、部署、複查、回滾都跑過。再部署一次後回滾，確認還原的是第一次部署前的檔案，而不是第二次備份。
4. `--purge-packages` 之後 `jq` 仍在。`/opt/zeek` 只有在另外加上 `--purge` 並確認後才消失。
