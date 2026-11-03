import { dirname, normalize, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { actionById } from "./actions.js";
import { App } from "./app.js";
import { runSelfCheck } from "./self-check.js";
import { Screen } from "./screen.js";

export function repoRootFromModule(importMetaUrl: string): string {
  return resolve(dirname(fileURLToPath(importMetaUrl)), "..", "..");
}

function printHelp(): void {
  console.log(`OpenRumble 第二階段 Zeek TUI

用法:
  node dist/main.js [--select 動作] [--self-check]

動作: deploy, dry-run, verify, logs, rollback, purge-packages, purge-tree
--self-check  不進全螢幕，只檢查選單、確認流程與腳本參數
`);
}

function parseArgs(argv: readonly string[]): { help: boolean; selfCheck: boolean; select: string | null } {
  let help = false;
  let selfCheck = false;
  let select: string | null = null;
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index] ?? "";
    if (arg === "--help" || arg === "-h") help = true;
    else if (arg === "--self-check") selfCheck = true;
    else if (arg === "--select") {
      const value = argv[index + 1];
      if (!value || value.startsWith("--")) throw new Error("--select 需要動作名稱");
      if (!actionById(value)) throw new Error(`未知動作: ${value}`);
      select = value;
      index += 1;
    } else {
      throw new Error(`未知參數: ${arg}`);
    }
  }
  return { help, selfCheck, select };
}

export async function main(argv: readonly string[], repoRoot: string): Promise<number> {
  const options = parseArgs(argv);
  if (options.help) {
    printHelp();
    return 0;
  }
  if (options.selfCheck) {
    await runSelfCheck(repoRoot);
    return 0;
  }
  const app = new App(repoRoot, options.select);
  const screen = new Screen(app);
  screen.start();
  return 0;
}

const entry = process.argv[1];
const executedDirectly = entry !== undefined && normalize(fileURLToPath(import.meta.url)).toLowerCase() === normalize(resolve(entry)).toLowerCase();
if (executedDirectly) {
  main(process.argv.slice(2), repoRootFromModule(import.meta.url)).catch((error: unknown) => {
    const message = error instanceof Error ? error.message : String(error);
    console.error(message);
    process.exit(1);
  });
}
