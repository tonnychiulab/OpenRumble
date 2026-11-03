# 第二階段 Zeek TUI

OpenRumble 的 Zeek 操作畫面。互動方式對照 [oh-my-pi](https://github.com/can1357/oh-my-pi) 的 `@oh-my-pi/pi-tui`：狀態欄、鍵盤選單、確認畫面、執行中的輸出。上游渲染器要 Bun，而且 `ProcessTerminal` 直接使用 `bun:ffi`，所以這個目錄用 TypeScript 與 Node 實作同一套操作，不把 oh-my-pi 整個放進倉庫。

部署、回滾、複查都呼叫倉庫根目錄的腳本，不在這裡重寫 apt 或 zeekctl。

## 建置與啟動

```bash
cd phase2-tui
npm install
npm run build
```

在 Ubuntu 24.04 上以 root 啟動：

```bash
sudo bash phase2-tui/obm-zeek-tui.sh
sudo bash phase2-tui/obm-zeek-tui.sh --select rollback
```

`obm_runtime_manager.sh` 的第二階段選項也是呼叫這個啟動器。需要 Node.js 18 以上。`dist/main.js` 建好後，目標主機不必再執行 npm。

檢查（不進全螢幕）：

```bash
npm run check
```

## 可以做什麼

- 每兩秒以唯讀指令更新 zeekctl、介面、JSON、輪替與金鑰指紋
- 正式部署、dry-run、唯讀複查
- 回滾設定。卸載 zeek 套件時保留 jq，也不會順便刪除 `/opt/zeek`
- 刪除 `/opt/zeek` 前必須輸入 `DELETE`
- 執行中按 Esc 會對腳本行程群組送出 SIGTERM

按鍵：↑↓ 或 j/k 移動，Enter 執行，Esc 取消，打字篩選，r 重新整理，? 說明，q 離開。
