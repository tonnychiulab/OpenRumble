# 共同事件格式與關聯鍵規格

| 項目 | 內容 |
|---|---|
| 文件版本 | v0.1（草案） |
| 適用專案 | OpenRumble |
| 狀態 | 🚧 設計階段，欄位與規則尚未實作，可能調整 |

> **查證提醒：** 本文件引用的 Falco、auditd、Zeek 欄位名稱是依各工具的常見輸出整理，實際欄位會因版本與設定而異。實作前請以你部署的版本實測輸出為準。

---

## 1. 目標與範圍

OpenRumble 同時接收三種來源：

| 來源 | 視角 | 本專案模組 |
|---|---|---|
| Falco（eBPF） | 主機核心層行為，依規則產生告警 | `footfall` |
| auditd | 主機稽核紀錄，依稽核規則產生 | `matriarch` |
| Zeek | 網路連線與協定中繼資料 | `rumble` |

三者的時間格式、欄位名稱、事件粒度都不同。本文件定義：

1. **共同事件格式**：三種來源正規化後的統一結構。
2. **關聯鍵**：怎麼判斷不同來源的事件在講同一件事。
3. **交叉驗證規則**：Falco 與 auditd 的事件如何互相比對，以及比對結果的意義。

**不在本文件範圍：** 風險評分模型、風險登記簿資料模型、輸出端（Graylog / OpenSearch）的索引設計。本文件只預留對應欄位。

## 2. 設計原則

1. **保留原始資料**：正規化不能丟失資訊，原始事件完整放在 `raw` 欄位，方便稽核與重新解析。
2. **欄位命名參考 ECS**：`@timestamp`、`host.*`、`process.*`、`source.*`、`destination.*` 等沿用 Elastic Common Schema 的命名習慣，以降低日後串接 OpenSearch 的成本。OpenRumble 自訂的欄位一律放在 `orr.*` 底下，避免跟標準欄位衝突。*（此為提案，尚待確認是否採用）*
3. **不確定就標示，不要猜**：無法取得的欄位留空，並用 `orr.quality.*` 標記原因，不要用預設值填充。
4. **時間一律轉成 UTC**，並記錄原始精度。

## 3. 共同事件格式

### 3.1 欄位總表

| 欄位 | 型別 | 必填 | 說明 |
|---|---|---|---|
| `schema_version` | string | ✔ | 事件格式版本，例如 `0.1` |
| `@timestamp` | string | ✔ | 事件發生時間，UTC，RFC 3339，保留到奈秒 |
| `event.id` | string | ✔ | OpenRumble 產生的唯一 ID（建議 ULID） |
| `event.original_id` | string | | 來源系統的事件識別（見 §3.3） |
| `event.source` | enum | ✔ | `falco` / `auditd` / `zeek` |
| `event.kind` | enum | ✔ | `event`（一般紀錄）/ `alert`（規則告警） |
| `event.category` | enum | ✔ | `process` / `file` / `network` / `authentication` / `configuration` / `other` |
| `event.action` | string | | 標準化動作，例如 `exec`、`open`、`connect`、`unlink`、`chmod` |
| `event.outcome` | enum | | `success` / `failure` / `unknown` |
| `host.id` | string | ✔ | 主機唯一識別（見 §4.1） |
| `host.name` | string | | 主機名稱 |
| `process.pid` | int | | 行程 PID（主機命名空間，見 §8） |
| `process.ppid` | int | | 父行程 PID |
| `process.name` | string | | 行程名稱 |
| `process.executable` | string | | 可執行檔完整路徑 |
| `process.command_line` | string | | 完整指令列 |
| `process.entity_id` | string | | 行程實體 ID，用來區分 PID 重複使用（見 §4.2） |
| `process.parent.name` | string | | 父行程名稱 |
| `user.id` | string | | 有效使用者 UID |
| `user.name` | string | | 使用者名稱 |
| `user.audit_id` | string | | 登入時的原始使用者 ID（auditd 的 `auid`、Falco 的 `user.loginuid`），不會因 `su`、`sudo` 而改變 |
| `file.path` | string | | 涉及的檔案路徑 |
| `source.ip` / `source.port` | string / int | | 連線來源 |
| `destination.ip` / `destination.port` | string / int | | 連線目的 |
| `network.transport` | string | | `tcp` / `udp` / `icmp` 等 |
| `network.community_id` | string | | Community ID 流量雜湊（見 §4.3） |
| `container.id` | string | | 容器 ID（若在容器內） |
| `rule.name` | string | | 觸發的規則名稱（Falco 規則或 auditd `key`） |
| `rule.severity` | string | | 規則嚴重度（原始值保留，另有標準化對應） |
| `orr.correlation.id` | string | | 關聯後的事件群組 ID |
| `orr.correlation.keys` | object | | 本事件可用的關聯鍵清單（見 §4） |
| `orr.crosscheck.status` | enum | | 交叉驗證結果（見 §5） |
| `orr.confidence` | enum | | `high` / `medium` / `low` |
| `orr.mitre.technique` | array | | 對應的 MITRE ATT&CK 技術編號（預留） |
| `orr.control.iso27001` | array | | 對應的 ISO 27001:2022 附錄 A 控制項（預留） |
| `orr.risk.ids` | array | | 對應的風險登記簿項目（預留） |
| `orr.quality.notes` | array | | 欄位缺漏或精度降低的原因 |
| `raw` | object / string | ✔ | 原始事件 |

### 3.2 時間處理

| 來源 | 原始時間格式 | 精度 | 備註 |
|---|---|---|---|
| Falco | 事件發生時間（JSON 輸出的 `time`；欄位 `evt.rawtime` 為奈秒） | 奈秒 | 使用主機時間 |
| auditd | `msg=audit(秒.毫秒:序號)` | 毫秒 | 同一事件的多筆紀錄共用相同時間與序號 |
| Zeek | `ts`，浮點數的 epoch 秒 | 微秒 | 連線的 `ts` 是連線開始時間，不是結束時間 |

轉換規則：

- 一律轉成 UTC 的 RFC 3339。
- 精度低的來源在 `orr.quality.notes` 記錄 `timestamp_precision=ms` 之類的資訊。
- 因為精度不同，跨來源比對必須使用時間窗，不能要求時間完全相等（見 §6）。
- **前提：所有主機與 Zeek 感測器必須做時間同步**（NTP 或 chrony）。時鐘偏移直接影響關聯準確度，建議把「各節點的時鐘偏移量」列入 `rumble scan` 的檢查項目。

### 3.3 `event.original_id` 規則

| 來源 | 組成方式 | 注意事項 |
|---|---|---|
| Falco | 無原生事件 ID。以 `host.id` + 時間（奈秒）+ `rule` + `process.pid` 的雜湊產生 | 屬於衍生 ID，非來源提供 |
| auditd | `host.id` + 時間 + 序號（`audit(時間:序號)`） | 序號在主機重新開機後會重置，因此必須搭配時間與主機 |
| Zeek | 連線的 `uid`（每個連線唯一，如 `C...`） | 以 `uid` 串接 `conn.log`、`dns.log`、`ssl.log`、`http.log` 等 |

## 4. 關聯鍵

每個正規化事件可以帶多把關聯鍵，關聯器依優先順序嘗試。

### 4.1 `host.id`

主機識別必須穩定。建議優先順序：

1. `/etc/machine-id`
2. 雲端或虛擬化平台提供的實例 ID
3. 主機名稱（最後手段，可能重複或變動）

Falco、auditd 的 agent 在轉送事件時，由 agent 端統一附加 `host.id`，不要在接收端猜。

### 4.2 行程鍵：`process.entity_id`

**問題：** PID 會被重複使用，單看 `host + pid` 在長時間窗內會錯誤關聯。

**提案：** 關聯器在看到行程的 `exec` 事件時建立實體：

```
process.entity_id = hash(host.id, process.pid, process.start_time)
```

- `process.start_time` 優先使用來源提供的行程啟動時間；若來源沒有，則用該行程第一次出現 `exec` 事件的時間代替。
- 若查不到對應的實體（例如事件發生在 OpenRumble 啟動之前），退回使用 `host.id + process.pid + 時間窗`，並在 `orr.quality.notes` 標記 `entity_id=fallback`。

### 4.3 網路鍵：`network.community_id`

[Community ID](https://github.com/corelight/community-id-spec) 是依五元組（來源 IP、來源埠、目的 IP、目的埠、協定）計算的流量雜湊，目的是讓不同工具對同一條連線得到相同的識別字串。

- **Zeek**：可在 `conn.log` 輸出 `community_id` 欄位。是否內建取決於 Zeek 版本，舊版需要另外安裝套件或載入對應的 policy，請依你的環境確認。
- **Falco**：網路事件有完整五元組（例如 `fd.cip`、`fd.cport`、`fd.sip`、`fd.sport`、`fd.l4proto`），OpenRumble 在正規化階段自行計算 Community ID。
- **auditd**：`connect()` 的 `SOCKADDR` 紀錄只包含**目的位址與埠**，**沒有本機來源埠**，無法算出完整的 Community ID。只能用目的 IP、目的埠與時間窗做較弱的比對（見 §6.3）。

### 4.4 使用者鍵：`user.audit_id`

`auid` / `loginuid` 在整個登入工作階段中不變，即使後來 `sudo` 成了 root 也能追到最初的登入者。對於「誰做的」這個風險管理的核心問題，這個欄位比 `user.id` 更重要，兩邊都要盡量保留。

### 4.5 關聯鍵總覽

| 關聯鍵 | 用途 | Falco | auditd | Zeek |
|---|---|:-:|:-:|:-:|
| `host.id` | 限定同一台主機 | ✔ | ✔ | — |
| `process.entity_id` | 主機內事件關聯 | ✔ | ✔ | — |
| `user.audit_id` | 追溯操作者 | ✔ | ✔ | — |
| `network.community_id` | 主機與網路事件關聯 | ✔（自行計算） | ✘（缺來源埠） | ✔ |
| 目的 IP + 目的埠 + 時間窗 | 弱關聯 | ✔ | ✔ | ✔ |
| Zeek `uid` | 串接同一連線的各種 Zeek 日誌 | — | — | ✔ |

## 5. 交叉驗證：Falco 與 auditd

### 5.1 `orr.crosscheck.status` 定義

| 狀態 | 意義 |
|---|---|
| `confirmed` | 兩邊在時間窗內都看到同一個行為 |
| `falco_only` | 只有 Falco 看到，而 auditd 對該類別**有設定覆蓋** |
| `auditd_only` | 只有 auditd 看到，而 Falco 對該類別**有設定覆蓋** |
| `not_comparable` | 某一邊對該類別沒有設定覆蓋，無法比較（**不是異常**） |
| `pending` | 還在等待時間窗結束 |

### 5.2 一個關鍵前提：覆蓋矩陣

Falco 只會對**符合規則**的行為產生事件，auditd 只會對**符合稽核規則**的行為產生紀錄。如果某類行為只有一邊有規則，另一邊「沒看到」是理所當然的，不能解讀成偵測被繞過。

因此需要一份**覆蓋矩陣**（建議放在 `config/coverage.yaml`），明確宣告兩邊各自覆蓋哪些事件類別：

```yaml
# 草案
coverage:
  - category: process
    action: exec
    falco:  { covered: true,  rules: ["..."] }
    auditd: { covered: true,  keys:  ["exec_watch"] }
  - category: network
    action: connect
    falco:  { covered: true,  rules: ["..."] }
    auditd: { covered: false }          # 此類別無法比較 → not_comparable
```

只有兩邊都標示 `covered: true` 的類別，才會做 `falco_only` / `auditd_only` 的判定。這也提供了一個附帶價值：`rumble scan` 可以檢查矩陣宣告與實際載入的規則是否一致。

### 5.3 事件對應表（草案）

| 共同動作 `event.action` | Falco | auditd |
|---|---|---|
| `exec` | `execve` / `execveat` | `SYSCALL`（`execve`）+ `EXECVE` |
| `open` | `open` / `openat` | `SYSCALL`（`openat`）+ `PATH` |
| `connect` | `connect` | `SYSCALL`（`connect`）+ `SOCKADDR` |
| `unlink` | `unlink` / `unlinkat` | `SYSCALL`（`unlinkat`）+ `PATH` |
| `chmod` | `chmod` / `fchmodat` | `SYSCALL`（`fchmodat`）+ `PATH` |
| `setuid` | `setuid` 系列 | `SYSCALL`（`setuid` 系列） |

> auditd 的一個「事件」由同一序號的多筆紀錄組成（`SYSCALL`、`EXECVE`、`PATH`、`CWD`、`PROCTITLE` 等），正規化前必須先依 `audit(時間:序號)` 組合成一筆。

### 5.4 比對規則

事件 A（Falco）與事件 B（auditd）視為同一行為，需同時滿足：

1. `host.id` 相同
2. `event.action` 相同（依 §5.3 對應）
3. 行程相同：`process.entity_id` 相同；若為 fallback，則 `process.pid` 相同
4. 時間差在時間窗內：`|A.@timestamp − B.@timestamp| ≤ Δ`
5. 資源相同（視動作而定）：`file.path` 相同（檔案類）、`destination.ip` + `destination.port` 相同（連線類）

**時間窗 Δ**：預設值待實測決定，必須可設定。考量因素：auditd 毫秒精度、兩邊處理延遲、主機時鐘偏移。

### 5.5 `falco_only` / `auditd_only` 的可能原因

這個狀態只代表「需要查證」，不代表有問題。常見原因：

| 可能原因 | 如何判斷 |
|---|---|
| 規則缺口 | 檢查該行為是否真的符合另一邊的規則條件 |
| 事件遺失 | 檢查 Falco 的 drop 統計、auditd 的 `backlog` 與 lost 計數 |
| 處理延遲超出時間窗 | 調高 Δ 後重新比對 |
| 時鐘不同步 | 檢查各節點時間偏移 |
| 偵測機制被繞過或停用 | 同時檢查 agent 是否在該時段曾停止或重啟 |

OpenRumble 的責任是把這些線索一起附在事件上，由人判斷，而不是自動下結論。

## 6. 主機與網路的關聯

### 6.1 強關聯：Community ID

主機事件（Falco）與 Zeek 的 `conn.log` 計算出相同的 `network.community_id`，且時間重疊 → 視為同一條連線。此時可以把「哪個行程、哪個使用者」與「連去哪裡、傳了多少資料」串在一起。

### 6.2 協定日誌串接

Zeek 的 `dns.log`、`ssl.log`、`http.log`、`files.log` 都帶 `uid`。先透過 §6.1 找到 `conn.log` 的 `uid`，再用 `uid` 取得 DNS 查詢名稱、TLS 的 SNI 等資訊，補充到主機事件上。

### 6.3 弱關聯：auditd 與 Zeek

由於 auditd 沒有來源埠，只能用以下條件比對，並把 `orr.confidence` 降為 `medium` 或 `low`：

- 同一個 `host.id` 的對外 IP 對應到 Zeek 連線的來源 IP
- `destination.ip` + `destination.port` 相同
- 時間落在 Zeek 連線的 `ts` 到結束時間之間

若同一主機在短時間內對同一目的地有多條連線，弱關聯會產生歧義，此時應保留所有候選連線，不要任選一條。

### 6.4 NAT 與位置

Zeek 感測器若位於 NAT 之後或之前，看到的 IP 會不同。部署文件需要說明感測器位置，並提供位址對應表（`config/address-map.yaml`，草案），讓關聯器能把 NAT 前後的位址對上。

## 7. 範例

以下範例使用文件保留的測試 IP（`192.0.2.0/24`、`203.0.113.0/24`）。這是一個虛構的情境：一台主機上的 Web 服務行程啟動了 shell，並對外建立連線。

**正規化後的 Falco 事件（簡化）**

```json
{
  "schema_version": "0.1",
  "@timestamp": "2026-11-03T15:20:11.482913000Z",
  "event.id": "01JEXAMPLE0000000000000001",
  "event.source": "falco",
  "event.kind": "alert",
  "event.category": "process",
  "event.action": "exec",
  "host.id": "a1b2c3d4e5f6",
  "process.pid": 4021,
  "process.ppid": 1180,
  "process.name": "sh",
  "process.executable": "/usr/bin/dash",
  "process.entity_id": "pe_7f3a9c",
  "process.parent.name": "nginx",
  "user.audit_id": "4294967295",
  "rule.name": "（Falco 規則名稱）",
  "orr.crosscheck.status": "confirmed",
  "orr.confidence": "high",
  "raw": { "…": "Falco 原始 JSON" }
}
```

**對應的 auditd 事件（組合自同一序號的多筆紀錄）**

```json
{
  "@timestamp": "2026-11-03T15:20:11.483000000Z",
  "event.source": "auditd",
  "event.category": "process",
  "event.action": "exec",
  "host.id": "a1b2c3d4e5f6",
  "process.pid": 4021,
  "process.entity_id": "pe_7f3a9c",
  "rule.name": "exec_watch",
  "orr.quality.notes": ["timestamp_precision=ms"]
}
```

兩者主機、動作、行程實體相同，時間差約 87 微秒，落在時間窗內 → `confirmed`。

**後續的對外連線**

```json
{
  "event.source": "falco",
  "event.category": "network",
  "event.action": "connect",
  "process.entity_id": "pe_7f3a9c",
  "destination.ip": "203.0.113.50",
  "destination.port": 4444,
  "network.transport": "tcp",
  "network.community_id": "1:（雜湊值）"
}
```

Zeek 的 `conn.log` 若有相同的 `community_id`，即可把這條連線與上面的行程鏈串在一起：**nginx → sh → 連往 203.0.113.50:4444**。這就是 OpenRumble 要提供的「從單一訊號走到完整脈絡」。

## 8. 待決議事項

| # | 問題 | 說明 |
|---|---|---|
| 1 | 欄位命名是否正式採用 ECS | 影響後續與 OpenSearch、Graylog 的整合 |
| 2 | 時間窗 Δ 的預設值 | 需要用實際環境的資料測量 |
| 3 | 容器環境的 PID | Falco 的 `proc.pid` 與 `proc.vpid`（容器內 PID）的差異，以及 auditd 在容器內事件所記錄的 PID 是否一致，需實測 |
| 4 | `process.start_time` 的來源 | 兩邊都不一定直接提供，需確認可用的欄位，或採用「首次 exec 時間」的替代方案 |
| 5 | Falco 事件的 `event.original_id` | 無原生 ID，衍生方式是否足夠穩定、是否可能碰撞 |
| 6 | 高流量下的效能 | 關聯器需要在記憶體中保留一個時間窗的事件，需評估容量與淘汰策略 |
| 7 | 覆蓋矩陣如何維護 | 手動維護容易與實際規則脫節，是否可由規則檔自動產生 |
| 8 | 嚴重度標準化 | Falco 的 `priority` 與自訂的風險嚴重度如何對應 |

## 9. 後續工作

- [ ] 用實際環境的 Falco、auditd、Zeek 輸出，驗證本文件的欄位對照
- [ ] 實作 auditd 多筆紀錄的組合器
- [ ] 實作 Community ID 計算（Falco 側）
- [ ] 實作 `process.entity_id` 追蹤
- [ ] 寫出覆蓋矩陣的 schema 與 `rumble scan` 的檢查邏輯
- [ ] 決議 §8 的待決議事項後，將本文件升為 v0.2
