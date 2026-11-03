import { existsSync } from "node:fs";

import {
  ACTIONS,
  actionById,
  commandText,
  confirmLines,
  scriptPath,
  type ActionSpec,
} from "./actions.js";
import { isBackspace, isCtrlC, isCtrlL, isEnter, isEscape } from "./keys.js";
import { emptyStatus, probeStatus, type StatusSnapshot } from "./probe.js";
import { LOG_TAIL, startProcess, type RunRequest, type TaskRunner } from "./runner.js";
import { SelectList } from "./select-list.js";
import { bgBlue, bgRed, cyan, dim, green, paint, red, yellow } from "./style.js";
import { fit, padVisible } from "./width.js";

type Mode =
  | { kind: "menu" }
  | { kind: "help" }
  | { kind: "confirm"; action: ActionSpec }
  | { kind: "phrase"; action: ActionSpec; typed: string; note: string }
  | { kind: "run"; action: ActionSpec; lines: string[] }
  | { kind: "result"; action: ActionSpec; lines: string[]; code: number | null };

const SPINNER = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"];

export class App {
  readonly list: SelectList;
  onChange: (() => void) | null = null;
  onExit: ((code: number) => void) | null = null;
  private mode: Mode = { kind: "menu" };
  private status: StatusSnapshot;
  private viewport = 24;
  private spinner = 0;
  private poll: ReturnType<typeof setInterval> | null = null;
  private spinTimer: ReturnType<typeof setInterval> | null = null;
  private task: { abort: () => void } | null = null;
  private pending: Promise<void> | null = null;
  private probeToken = 0;
  private forceFull = false;

  constructor(
    private readonly repoRoot: string,
    select: string | null,
    private readonly runner: TaskRunner = { start: startProcess },
  ) {
    this.list = new SelectList(ACTIONS);
    this.status = emptyStatus("按 r 重新整理狀態。");
    if (select) this.list.setSelectedId(select);
    this.list.onSelect = (item) => this.choose(item);
    this.list.onCancel = () => this.requestQuit();
  }

  view(): Mode["kind"] {
    return this.mode.kind;
  }

  setViewport(rows: number): void {
    this.viewport = Math.max(8, rows);
  }

  consumeFullRedraw(): boolean {
    const force = this.forceFull;
    this.forceFull = false;
    return force;
  }

  start(): void {
    void this.refresh();
    this.poll = setInterval(() => {
      if (this.mode.kind === "menu") void this.refresh();
    }, 2000);
  }

  stop(): void {
    if (this.poll) clearInterval(this.poll);
    if (this.spinTimer) clearInterval(this.spinTimer);
    this.poll = null;
    this.spinTimer = null;
    this.task?.abort();
  }

  idle(): Promise<void> {
    return this.pending ?? Promise.resolve();
  }

  handleInput(data: string): void {
    if (isCtrlL(data)) {
      this.forceFull = true;
      this.requestRender();
      return;
    }
    if (isCtrlC(data)) {
      if (this.mode.kind === "run") this.abortRun();
      else this.requestQuit();
      return;
    }
    switch (this.mode.kind) {
      case "menu":
        this.handleMenu(data);
        break;
      case "help":
        if (isEscape(data) || isEnter(data) || data === "q") this.mode = { kind: "menu" };
        break;
      case "confirm":
        if (isEscape(data) || data === "q") this.mode = { kind: "menu" };
        else if (isEnter(data)) this.begin(this.mode.action);
        break;
      case "phrase":
        this.handlePhrase(data);
        break;
      case "run":
        if (isEscape(data)) this.abortRun();
        break;
      case "result":
        if (isEnter(data) || isEscape(data) || data === "q") {
          this.mode = { kind: "menu" };
          void this.refresh();
        }
        break;
      default:
        break;
    }
    this.requestRender();
  }

  render(width: number): readonly string[] {
    const lines: string[] = [];
    lines.push(paint(padVisible(" OpenRumble  ·  Phase 2 Zeek ", width), bgBlue));
    lines.push(fit(paint("狀態欄、方向鍵選單、確認後才執行腳本、輸出即時捲動。Esc 返回。", dim), width));
    lines.push("");
    if (this.mode.kind === "help") {
      lines.push(...this.helpLines(width));
    } else if (this.mode.kind === "confirm" || this.mode.kind === "phrase") {
      lines.push(...this.confirmView(width));
    } else if (this.mode.kind === "run" || this.mode.kind === "result") {
      lines.push(...this.outputView(width));
    } else {
      lines.push(...this.dashboard(width));
    }
    return lines.slice(0, this.viewport).map((line) => fit(line, width));
  }

  private handleMenu(data: string): void {
    if ((data === "q") && this.list.filterLength() === 0) {
      this.requestQuit();
      return;
    }
    if (data === "r" && this.list.filterLength() === 0) {
      void this.refresh();
      return;
    }
    if (data === "?" && this.list.filterLength() === 0) {
      this.mode = { kind: "help" };
      return;
    }
    this.list.handleInput(data);
  }

  private handlePhrase(data: string): void {
    if (this.mode.kind !== "phrase") return;
    if (isEscape(data)) {
      this.mode = { kind: "menu" };
      return;
    }
    if (isBackspace(data)) {
      this.mode = { ...this.mode, typed: this.mode.typed.slice(0, -1), note: "" };
      return;
    }
    if (isEnter(data)) {
      if (this.mode.typed === this.mode.action.phrase) this.begin(this.mode.action);
      else this.mode = { ...this.mode, note: "必須是大寫 DELETE" };
      return;
    }
    if (/^[A-Za-z]$/.test(data)) {
      this.mode = { ...this.mode, typed: this.mode.typed + data, note: "" };
    }
  }

  private choose(action: ActionSpec): void {
    if (action.id === "quit") {
      this.requestQuit();
      return;
    }
    if (action.id === "logs") {
      this.begin(action);
      return;
    }
    if (action.phrase) {
      this.mode = { kind: "phrase", action, typed: "", note: "" };
      return;
    }
    this.mode = { kind: "confirm", action };
  }

  private begin(action: ActionSpec): void {
    const request = this.requestFor(action);
    if (!request) return;
    const lines: string[] = [`$ ${commandText(this.repoRoot, action)}`];
    this.mode = { kind: "run", action, lines };
    this.spinner = 0;
    if (this.spinTimer) clearInterval(this.spinTimer);
    this.spinTimer = setInterval(() => {
      this.spinner = (this.spinner + 1) % SPINNER.length;
      if (this.mode.kind === "run") this.requestRender();
    }, 100);
    const task = this.runner.start(request, (line) => {
      const mode = this.mode;
      if (mode.kind !== "run" && mode.kind !== "result") return;
      const next = [...mode.lines, line].slice(-400);
      if (mode.kind === "run") this.mode = { kind: "run", action, lines: next };
      this.requestRender();
    });
    this.task = task;
    this.pending = task.finished.then((code) => {
      this.task = null;
      if (this.spinTimer) clearInterval(this.spinTimer);
      this.spinTimer = null;
      const current = this.mode.kind === "run" ? this.mode.lines : lines;
      this.mode = { kind: "result", action, lines: current, code };
      this.requestRender();
    });
  }

  private requestFor(action: ActionSpec): RunRequest | null {
    if (action.id === "logs") {
      return { file: "bash", args: ["-c", LOG_TAIL], cwd: this.repoRoot };
    }
    if (!action.script) return null;
    const file = scriptPath(this.repoRoot, action.script);
    if (!existsSync(file)) {
      this.mode = {
        kind: "result",
        action,
        lines: [`找不到腳本: ${file}`],
        code: 1,
      };
      return null;
    }
    return { file: "bash", args: [file, ...action.args], cwd: this.repoRoot };
  }

  private abortRun(): void {
    this.task?.abort();
  }

  private async refresh(): Promise<void> {
    const token = ++this.probeToken;
    const snapshot = await probeStatus();
    if (token !== this.probeToken) return;
    this.status = snapshot;
    this.requestRender();
  }

  private requestQuit(): void {
    this.stop();
    this.onExit?.(0);
  }

  private requestRender(): void {
    this.onChange?.();
  }

  private dashboard(width: number): string[] {
    const rows = [
      paint("即時狀態", cyan),
      this.statusLine("系統", `${this.status.os}    uid=${this.status.root}`),
      this.statusLine("zeekctl", this.zeekLabel()),
      this.statusLine("介面", this.ifaceLabel()),
      this.statusLine("JSON", this.jsonLabel()),
      this.statusLine("輪替", this.rotateLabel()),
      this.statusLine("金鑰指紋", this.status.fingerprint || "尚未匯入"),
    ];
    if (this.status.detail) rows.push(fit(paint(this.status.detail, yellow), width));
    rows.push("");
    rows.push(paint("操作    輸入文字可篩選，像 oh-my-pi 的選單", cyan));
    const used = rows.length + 4;
    this.list.setMaxVisible(Math.max(3, this.viewport - used));
    rows.push(...this.list.render(width));
    rows.push("");
    rows.push(fit(paint("↑↓/jk 移動   Enter 執行   r 重新整理   ? 按鍵   q 離開", dim), width));
    return rows;
  }

  private confirmView(width: number): string[] {
    const action = this.mode.kind === "confirm" || this.mode.kind === "phrase" ? this.mode.action : ACTIONS[0];
    if (!action) return [];
    const banner = action.destructive ? bgRed : bgBlue;
    const title = action.destructive ? " 確認破壞性操作 " : " 確認要執行的指令 ";
    const rows = [paint(padVisible(title, width), banner), ""];
    for (const line of confirmLines(this.repoRoot, action)) rows.push(fit(line, width));
    if (this.mode.kind === "phrase") {
      rows.push("");
      rows.push(fit(`輸入: ${this.mode.typed}`, width));
      if (this.mode.note) rows.push(fit(paint(this.mode.note, red), width));
    }
    return rows;
  }

  private outputView(width: number): string[] {
    const mode = this.mode;
    if (mode.kind !== "run" && mode.kind !== "result") return [];
    const running = mode.kind === "run";
    const frame = SPINNER[this.spinner] ?? "⠋";
    const title = running
      ? paint(` ${frame} 執行中  Esc 中止 `, yellow)
      : this.resultTitle(mode.code);
    const rows = [fit(title, width), ""];
    const budget = Math.max(4, this.viewport - 6);
    const tail = mode.lines.slice(-budget);
    if (tail.length === 0) rows.push(paint("等待輸出...", dim));
    for (const line of tail) rows.push(fit(line, width));
    rows.push("");
    rows.push(
      fit(
        running
          ? paint("輸出來自腳本本身。Esc 送出 SIGTERM。", dim)
          : paint("Enter 返回狀態畫面", dim),
        width,
      ),
    );
    return rows;
  }

  private resultTitle(code: number | null): string {
    if (code === null) return paint(" 已中止 ", yellow);
    if (code === 0) return paint(" 離開碼 0  腳本回報完成 ", green);
    if (code === 2) return paint(" 離開碼 2  操作者在腳本裡中止 ", yellow);
    return paint(` 離開碼 ${code}  未完成 `, red);
  }

  private helpLines(width: number): string[] {
    const lines = [
      "按鍵跟 oh-my-pi 的選單同一套習慣：",
      "  ↑ ↓ 或 j k     移動",
      "  Enter          選取。破壞性動作會先確認",
      "  Esc            取消、清除篩選、中止執行中的腳本",
      "  打字           篩選選單",
      "  r              重新讀 Zeek 狀態（唯讀）",
      "  Ctrl+L         整頁重畫",
      "  q 或 Ctrl+C    離開",
      "",
      "部署、回滾、複查都是 bash 執行倉庫裡的腳本。",
      "這個畫面不重寫 apt 或 zeekctl。",
      "",
      "Esc 或 Enter 返回",
    ];
    return lines.map((line) => fit(line, width));
  }

  private statusLine(label: string, value: string): string {
    return `${label.padEnd(8, " ")} ${value}`;
  }

  private zeekLabel(): string {
    if (this.status.zeekctl === "running") return paint("running", green);
    if (this.status.zeekctl === "stopped" || this.status.zeekctl === "installed") {
      return paint(this.status.zeekctl, yellow);
    }
    return paint(this.status.zeekctl, red);
  }

  private ifaceLabel(): string {
    if (!this.status.iface) return paint("node.cfg 尚未指定", dim);
    const mark = this.status.ifaceExists === "yes" ? paint("存在", green) : paint("不存在", red);
    return `${this.status.iface}  ${mark}`;
  }

  private jsonLabel(): string {
    const setting = this.status.json === "yes" ? "設定已啟用" : "設定未啟用";
    const line = this.status.jsonLine === "yes" ? "current 已有 JSON 行" : "current 尚無 JSON 行";
    return `${setting}，${line}`;
  }

  private rotateLabel(): string {
    const cron = this.status.cron === "yes" ? "cron 已安裝" : "cron 未安裝";
    const rotate = this.status.logrotate === "yes" ? "logrotate 已安裝" : "logrotate 未安裝";
    const unsafe =
      this.status.copytruncateCurrent === "yes" ? paint("  current 仍被 copytruncate", red) : "";
    return `${cron}，${rotate}${unsafe}`;
  }
}

export function initialSelection(select: string | null): string | null {
  if (!select) return null;
  return actionById(select)?.id ?? null;
}
