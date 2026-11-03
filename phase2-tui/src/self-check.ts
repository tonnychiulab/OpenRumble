import { readFileSync } from "node:fs";
import { join } from "node:path";

import { ACTIONS, scriptPath, type ActionSpec } from "./actions.js";
import { App } from "./app.js";
import type { RunRequest, TaskRunner } from "./runner.js";
import { visibleWidth } from "./width.js";

function assert(condition: boolean, message: string): void {
  if (!condition) throw new Error(message);
}

function argsOf(id: ActionSpec["id"]): readonly string[] {
  const action = ACTIONS.find((item) => item.id === id);
  if (!action) throw new Error(`missing action ${id}`);
  return action.args;
}

function assertWidth(app: App, width: number): void {
  app.setViewport(24);
  const lines = app.render(width);
  lines.forEach((line, index) => {
    const widthNow = visibleWidth(line);
    if (widthNow > width) {
      throw new Error(`寬度 ${width} 的第 ${index} 行超出（${widthNow}）: ${line}`);
    }
  });
}

export async function runSelfCheck(repoRoot: string): Promise<void> {
  assert(argsOf("deploy").join(" ") === "--yes", "deploy 必須只帶 --yes");
  assert(argsOf("dry-run").join(" ") === "--dry-run", "dry-run 必須只帶 --dry-run");
  assert(argsOf("verify").length === 0, "verify 不帶會改系統的旗標");
  assert(argsOf("rollback").join(" ") === "--yes", "rollback 必須帶 --yes");
  assert(
    argsOf("purge-packages").join(" ") === "--yes --purge-packages",
    "卸載套件必須帶 --yes --purge-packages",
  );
  assert(argsOf("purge-tree").join(" ") === "--yes --purge", "刪除目錄必須帶 --yes --purge");
  for (const action of ACTIONS) {
    assert(!action.args.includes("jq"), `${action.id} 不應把 jq 當參數`);
    if (action.script) assert(existsScript(repoRoot, action.script), `找不到 ${action.script}`);
  }

  const deployText = readFileSync(scriptPath(repoRoot, "deploy_phase2_zeek.sh"), "utf8");
  const rollbackText = readFileSync(scriptPath(repoRoot, "rollback_phase2_zeek.sh"), "utf8");
  const verifyText = readFileSync(scriptPath(repoRoot, "verify_phase2_zeek.sh"), "utf8");
  assert(!deployText.includes("/etc/profile"), "部署腳本不應提到登入殼層設定檔");
  assert(!deployText.includes("copytruncate"), "部署腳本不應對 current 日誌做截斷複製");
  assert(deployText.includes("--dearmor --yes"), "gpg 必須帶 --dearmor --yes");
  assert(deployText.includes("signed-by="), "APT 來源必須寫 signed-by");
  assert(deployText.includes("zeekctl status"), "部署必須檢查 zeekctl status");
  assert(!rollbackText.includes("/etc/profile"), "回滾腳本不應提到登入殼層設定檔");
  assert(!rollbackText.includes("purge -y jq"), "回滾不應卸載 jq");
  assert(!rollbackText.includes("purge -y zeek jq"), "回滾不應把 jq 和 zeek 一起 purge");
  assert(!activeLines(verifyText).some((line) => line.includes("apt-get")), "複查腳本不應呼叫 apt-get");
  assert(!activeLines(verifyText).some((line) => line.includes("zeekctl deploy")), "複查腳本不應呼叫 zeekctl deploy");
  assert(!verifyText.includes("tee -a"), "複查腳本不應寫日誌檔");

  const calls: RunRequest[] = [];
  const runner: TaskRunner = {
    start(request, onLine) {
      calls.push(request);
      onLine("self-check output");
      return { abort() {}, finished: Promise.resolve(0) };
    },
  };

  const app = new App(repoRoot, "rollback", runner);
  assert(app.view() === "menu", "啟動後應在選單");
  assertWidth(app, 40);
  assertWidth(app, 80);
  app.handleInput("\r");
  assert(app.view() === "confirm", "回滾應先確認");
  app.handleInput("\x1b");
  assert(app.view() === "menu", "Esc 應回到選單");

  const purge = new App(repoRoot, "purge-tree", runner);
  purge.handleInput("\r");
  assert(purge.view() === "phrase", "刪除 /opt/zeek 應要求輸入 DELETE");
  for (const char of "DELETE") purge.handleInput(char);
  purge.handleInput("\r");
  await purge.idle();
  assert(calls.length === 1, "確認後應恰好呼叫一次腳本");
  const call = calls[0];
  if (!call) throw new Error("沒有記錄到腳本呼叫");
  assert(call.file === "bash", "必須用 bash 執行腳本");
  assert(call.args[0] === scriptPath(repoRoot, "rollback_phase2_zeek.sh"), "必須呼叫回滾腳本");
  assert(call.args.slice(1).join(" ") === "--yes --purge", "刪除目錄的參數不對");
  assert(call.cwd === repoRoot, "工作目錄應是倉庫根目錄");
  assert(purge.view() === "result", "腳本結束後應顯示結果");
  assertWidth(purge, 80);

  const deploy = new App(repoRoot, "deploy", runner);
  deploy.handleInput("\r");
  deploy.handleInput("\r");
  await deploy.idle();
  const deployCall = calls[1];
  if (!deployCall) throw new Error("沒有記錄到部署呼叫");
  assert(deployCall.args.slice(1).join(" ") === "--yes", "部署確認後應帶 --yes");

  console.log("phase2-tui self-check: pass");
}

function activeLines(text: string): string[] {
  return text.split(/\r?\n/).map((line) => line.trim()).filter((line) => line.length > 0 && !line.startsWith("#"));
}

function existsScript(repoRoot: string, script: string): boolean {
  return readFileSync(join(repoRoot, script), "utf8").length > 0;
}
